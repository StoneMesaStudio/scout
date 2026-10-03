// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// An answer to something typed in the search field that turned out to be a sum.
public struct Calculation: Sendable, Equatable {
    /// What was typed, tidied up. Shown under the answer so it is obvious what was worked out.
    public let question: String
    /// The answer as it is shown: grouped thousands, and a unit where there is one.
    public let answer: String
    /// The answer as it is copied: no grouping, no unit, so it can be pasted into another sum.
    public let plain: String
}

/// Works out sums and unit conversions typed into the search field.
///
/// Everything here is arithmetic and lookup tables that ship with macOS, so it answers with the
/// network switched off. Currency is the one thing Spotlight does that is missing, and it is
/// missing on purpose: rates have to be fetched, and Scout contacts nothing.
///
/// The hard part is not the arithmetic, it is refusing. Nearly everything typed into this field is
/// a search, so anything that is not unambiguously a sum has to produce no answer at all: a stray
/// row reading "4" under the word somebody is looking for is worse than no calculator. The rule is
/// that every character has to be accounted for — a single letter that is not a unit or a keyword
/// means this was a search, not a sum.
public enum Calculator {

    public static func evaluate(_ text: String) -> Calculation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }

        if let conversion = convert(trimmed) { return conversion }
        guard !looksLikeADate(trimmed) else { return nil }
        return arithmetic(trimmed)
    }

    /// `2026-09-13` is a date, and `1/2/2026` is a date, but both are also valid arithmetic. Two or
    /// more separators with no spaces anywhere settles it: nobody writes a sum that way, and a row
    /// reading "2,004" under a date somebody is searching for is pure noise.
    private static func looksLikeADate(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Sums

    private static func arithmetic(_ text: String) -> Calculation? {
        guard let tokens = Lexer.tokens(in: text), tokens.contains(where: \.isOperator) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.isFinished, value.isFinite else { return nil }

        return Calculation(question: text, answer: grouped(value), plain: plain(value))
    }

    // MARK: - Conversions

    /// `12 ft in m`, `180 F in C`, `2 GB to MB`.
    ///
    /// Split on the *last* "in" or "to", because "in" is also inches and "12 in in cm" is a fair
    /// thing to type.
    private static func convert(_ text: String) -> Calculation? {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 3 else { return nil }

        // Work backwards through every "in" and "to" and take the first split that makes sense of
        // both halves. Last-one-wins alone is wrong in both directions: "12 in in cm" needs the
        // second, and "100 cm to in" ends with inches.
        let lowered = words.map { $0.lowercased() }
        for keyword in stride(from: words.count - 2, through: 1, by: -1)
        where lowered[keyword] == "in" || lowered[keyword] == "to" {
            let left = words[0..<keyword].joined(separator: " ")
            let target = words[(keyword + 1)...].joined(separator: " ")

            guard let (amount, fromUnit) = amountAndUnit(in: left),
                  let toUnit = Units.unit(named: target),
                  type(of: fromUnit) == type(of: toUnit)
            else { continue }

            let converted = Measurement(value: amount, unit: fromUnit).converted(to: toUnit)
            guard converted.value.isFinite else { continue }

            return Calculation(
                question: text,
                answer: "\(grouped(converted.value)) \(toUnit.symbol)",
                plain: plain(converted.value)
            )
        }
        return nil
    }

    /// `12 ft`, `12ft`, or `3 * 4 ft` — the unit is the last word, the sum is everything before it.
    private static func amountAndUnit(in text: String) -> (Double, Dimension)? {
        if let split = text.lastIndex(where: { $0.isNumber }), split < text.index(before: text.endIndex) {
            let number = String(text[...split])
            let name = String(text[text.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, let unit = Units.unit(named: name), let value = value(of: number) {
                return (value, unit)
            }
        }

        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 2, let unit = Units.unit(named: words[words.count - 1]),
              let value = value(of: words[0..<(words.count - 1)].joined(separator: " "))
        else { return nil }
        return (value, unit)
    }

    private static func value(of text: String) -> Double? {
        guard let tokens = Lexer.tokens(in: text) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.isFinished, value.isFinite else { return nil }
        return value
    }

    // MARK: - Writing the answer down

    private static func grouped(_ value: Double) -> String { format(value, grouping: true) }
    private static func plain(_ value: Double) -> String { format(value, grouping: false) }

    private static func format(_ value: Double, grouping: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        // −0 is an answer nobody wants to read.
        let tidied = value == 0 ? 0 : value
        return formatter.string(from: NSNumber(value: tidied)) ?? "\(tidied)"
    }
}

// MARK: - Reading what was typed

private enum Token: Equatable {
    case number(Double)
    case plus, minus, times, divide, power, percent, open, close

    var isOperator: Bool {
        switch self {
        case .plus, .minus, .times, .divide, .power, .percent: true
        case .number, .open, .close: false
        }
    }
}

private enum Lexer {

    /// Every character has to belong to a sum, or this was a search. "e-mail" has letters in it and
    /// comes back nil; "2026" comes back as one number and is rejected later for having no operator.
    static func tokens(in text: String) -> [Token]? {
        var tokens: [Token] = []
        var characters = Array(text)
        var i = 0

        while i < characters.count {
            let c = characters[i]

            if c == " " { i += 1; continue }

            if c.isNumber || c == "." {
                var digits = ""
                while i < characters.count, characters[i].isNumber || characters[i] == "." ||
                        (characters[i] == "," && i + 3 < characters.count && characters[i + 1].isNumber) {
                    if characters[i] != "," { digits.append(characters[i]) }
                    i += 1
                }
                guard let value = Double(digits) else { return nil }
                tokens.append(.number(value))
                continue
            }

            // "20% of 80" is the way people say it, so "of" multiplies.
            if c == "o" || c == "O", i + 1 < characters.count, characters[i + 1] == "f" || characters[i + 1] == "F" {
                let after = i + 2
                let isWholeWord = after >= characters.count || characters[after] == " "
                let isStandalone = i == 0 || characters[i - 1] == " "
                guard isWholeWord, isStandalone else { return nil }
                tokens.append(.times)
                i += 2
                continue
            }

            switch c {
            case "+": tokens.append(.plus)
            case "-", "\u{2212}": tokens.append(.minus)
            case "*", "\u{00D7}", "x", "X": tokens.append(.times)
            case "/", "\u{00F7}": tokens.append(.divide)
            case "^": tokens.append(.power)
            case "%": tokens.append(.percent)
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default: return nil
            }
            i += 1
        }

        return tokens.isEmpty ? nil : tokens
    }
}

/// Ordinary precedence, written out rather than handed to `NSExpression` — which will happily
/// evaluate things that are not arithmetic at all, and raises rather than returning nil when the
/// text makes no sense.
private struct Parser {
    let tokens: [Token]
    var position = 0

    var isFinished: Bool { position == tokens.count }

    private var current: Token? { position < tokens.count ? tokens[position] : nil }

    mutating func expression() -> Double? {
        guard var left = term() else { return nil }
        while let token = current, token == .plus || token == .minus {
            position += 1
            guard let right = term() else { return nil }
            left = token == .plus ? left + right : left - right
        }
        return left
    }

    private mutating func term() -> Double? {
        guard var left = power() else { return nil }
        while let token = current, token == .times || token == .divide {
            position += 1
            guard let right = power() else { return nil }
            if token == .divide {
                guard right != 0 else { return nil }
                left /= right
            } else {
                left *= right
            }
        }
        return left
    }

    private mutating func power() -> Double? {
        guard let base = unary() else { return nil }
        guard current == .power else { return base }
        position += 1
        guard let exponent = power() else { return nil }
        return pow(base, exponent)
    }

    private mutating func unary() -> Double? {
        if current == .minus { position += 1; return unary().map { -$0 } }
        if current == .plus { position += 1; return unary() }
        return primary()
    }

    private mutating func primary() -> Double? {
        switch current {
        case .number(let value):
            position += 1
            if current == .percent { position += 1; return value / 100 }
            return value
        case .open:
            position += 1
            guard let inner = expression(), current == .close else { return nil }
            position += 1
            return inner
        default:
            return nil
        }
    }
}

// MARK: - Units

private enum Units {

    static func unit(named raw: String) -> Dimension? {
        let name = raw.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "°", with: "")
        return table[name]
    }

    /// Written out rather than derived from symbols, because the symbols alone miss every word a
    /// person actually types: nobody searches for "3 m" when they mean metres half as often as they
    /// type "meters".
    private static let table: [String: Dimension] = {
        var t: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) { for n in names { t[n] = unit } }

        add(UnitLength.millimeters, "mm", "millimeter", "millimeters", "millimetre", "millimetres")
        add(UnitLength.centimeters, "cm", "centimeter", "centimeters", "centimetre", "centimetres")
        add(UnitLength.meters, "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, "km", "kilometer", "kilometers", "kilometre", "kilometres")
        add(UnitLength.inches, "in", "inch", "inches")
        add(UnitLength.feet, "ft", "foot", "feet")
        add(UnitLength.yards, "yd", "yard", "yards")
        add(UnitLength.miles, "mi", "mile", "miles")
        add(UnitLength.nauticalMiles, "nmi", "nauticalmile", "nauticalmiles")

        add(UnitMass.milligrams, "mg", "milligram", "milligrams")
        add(UnitMass.grams, "g", "gram", "grams")
        add(UnitMass.kilograms, "kg", "kilo", "kilos", "kilogram", "kilograms")
        add(UnitMass.metricTons, "t", "tonne", "tonnes", "metricton", "metrictons")
        add(UnitMass.ounces, "oz", "ounce", "ounces")
        add(UnitMass.pounds, "lb", "lbs", "pound", "pounds")
        add(UnitMass.stones, "st", "stone", "stones")

        add(UnitTemperature.celsius, "c", "celsius", "centigrade")
        add(UnitTemperature.fahrenheit, "f", "fahrenheit")
        add(UnitTemperature.kelvin, "k", "kelvin")

        add(UnitVolume.milliliters, "ml", "milliliter", "milliliters", "millilitre", "millilitres")
        add(UnitVolume.liters, "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.teaspoons, "tsp", "teaspoon", "teaspoons")
        add(UnitVolume.tablespoons, "tbsp", "tablespoon", "tablespoons")
        add(UnitVolume.fluidOunces, "floz", "fluidounce", "fluidounces")
        add(UnitVolume.cups, "cup", "cups")
        add(UnitVolume.pints, "pt", "pint", "pints")
        add(UnitVolume.quarts, "qt", "quart", "quarts")
        add(UnitVolume.gallons, "gal", "gallon", "gallons")

        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.kilometersPerHour, "kph", "kmh", "km/h")
        add(UnitSpeed.metersPerSecond, "m/s", "mps")
        add(UnitSpeed.knots, "kn", "knot", "knots")

        add(UnitDuration.seconds, "s", "sec", "secs", "second", "seconds")
        add(UnitDuration.minutes, "min", "mins", "minute", "minutes")
        add(UnitDuration.hours, "h", "hr", "hrs", "hour", "hours")

        add(UnitInformationStorage.bytes, "byte", "bytes")
        add(UnitInformationStorage.kilobytes, "kb", "kilobyte", "kilobytes")
        add(UnitInformationStorage.megabytes, "mb", "megabyte", "megabytes")
        add(UnitInformationStorage.gigabytes, "gb", "gigabyte", "gigabytes")
        add(UnitInformationStorage.terabytes, "tb", "terabyte", "terabytes")
        add(UnitInformationStorage.kibibytes, "kib")
        add(UnitInformationStorage.mebibytes, "mib")
        add(UnitInformationStorage.gibibytes, "gib")
        add(UnitInformationStorage.tebibytes, "tib")

        add(UnitArea.squareMeters, "sqm", "m2")
        add(UnitArea.squareKilometers, "sqkm", "km2")
        add(UnitArea.squareFeet, "sqft", "ft2")
        add(UnitArea.squareMiles, "sqmi", "mi2")
        add(UnitArea.acres, "acre", "acres")
        add(UnitArea.hectares, "ha", "hectare", "hectares")

        return t
    }()
}
