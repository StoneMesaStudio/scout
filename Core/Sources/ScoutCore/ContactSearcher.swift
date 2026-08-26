// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Contacts
import Foundation

/// One person found in Contacts.
public struct ContactHit: Identifiable, Sendable, Hashable {

    public let identifier: String
    public let name: String
    public let organization: String?
    public let phone: String?
    public let email: String?

    public var id: String { identifier }

    public init(identifier: String, name: String, organization: String?, phone: String?, email: String?) {
        self.identifier = identifier
        self.name = name
        self.organization = organization
        self.phone = phone
        self.email = email
    }

    /// What to show under the name: the number and address are the reason people search contacts.
    public var detail: String {
        [phone, email, organization].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Opens the card in Contacts.
    public var openURL: URL? {
        URL(string: "addressbook://\(identifier)")
    }
}

/// A contact with everything about it that is worth matching, which is a good deal more than
/// what gets shown.
///
/// A card filed under a company name can still have a person's first name on it — "JLC Plumbing"
/// with Jose in the first-name field — and searching for the person has to find it. So the
/// matching sees every name field, every number and every address on the card, not just the ones
/// the row displays.
public struct ContactRecord: Sendable {

    public let hit: ContactHit
    /// Every string on the card worth matching against.
    public let searchable: [String]
    /// Just the name fields — given, middle, family, previous, nickname. Kept apart from the rest
    /// so a street called Brewster is not ranked as if it were somebody's name.
    public let nameFields: [String]
    /// Company, department and job title.
    public let workFields: [String]
    /// Just the digits of every number, so "6522909" finds "1 (505) 652-2909".
    public let phoneDigits: [String]
    /// Whether the card has a note. macOS gates note access behind an entitlement Apple grants
    /// on request, so this is often false even when a note plainly exists.
    public let hasNote: Bool

    public init(
        hit: ContactHit,
        searchable: [String],
        phoneDigits: [String],
        nameFields: [String] = [],
        workFields: [String] = [],
        hasNote: Bool = false
    ) {
        self.hit = hit
        self.searchable = searchable
        self.phoneDigits = phoneDigits
        self.nameFields = nameFields
        self.workFields = workFields
        self.hasNote = hasNote
    }
}

/// Reads the Contacts store.
public struct ContactSearcher: Sendable {

    public enum Access: Sendable, Equatable {
        case notRequested
        case allowed
        case denied
    }

    public init() {}

    public var access: Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .allowed
        case .notDetermined: .notRequested
        default: .denied
        }
    }

    /// Ask once. macOS shows its own prompt; the answer is remembered by the system.
    public func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Built per call rather than held in a static: `CNKeyDescriptor` predates Sendable.
    private static func keysToFetch() -> [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPreviousFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactNoteKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
        ]
    }

    /// True when the store could not be read at all, as opposed to being genuinely empty — so a
    /// transient failure is retried rather than cached as "you have no contacts".
    public func loadFailed() -> Bool {
        guard access == .allowed else { return false }
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        do {
            var seen = false
            try CNContactStore().enumerateContacts(with: request) { _, stop in
                seen = true
                stop.pointee = true
            }
            return !seen
        } catch {
            return true
        }
    }

    /// Every contact, as records we can search ourselves.
    ///
    /// Apple's `predicateForContacts(matchingName:)` was the obvious route and it is wrong in both
    /// directions: searching "Jose" returned Joan, John and Joyce — it matches names that merely
    /// sound alike — while missing "Hernandez Jose" and "Sabutis Joseph" altogether.
    public func loadAll() -> [ContactRecord] {
        guard access == .allowed else { return [] }

        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch())
        request.unifyResults = true
        request.sortOrder = .givenName

        var records: [ContactRecord] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            records.append(Self.record(from: contact))
        }
        return records
    }

    static func record(from contact: CNContact) -> ContactRecord {
        let phones = contact.phoneNumbers.map(\.value.stringValue)
        let emails = contact.emailAddresses.map { $0.value as String }
        let addresses = contact.postalAddresses.map {
            [$0.value.street, $0.value.city, $0.value.state, $0.value.postalCode]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        let names = [
            contact.givenName, contact.middleName, contact.familyName,
            contact.previousFamilyName, contact.nickname,
        ].filter { !$0.isEmpty }

        let work = [contact.organizationName, contact.departmentName, contact.jobTitle]
            .filter { !$0.isEmpty }

        let hit = ContactHit(
            identifier: contact.identifier,
            name: displayName(for: contact),
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            phone: phones.first,
            email: emails.first
        )

        let note = (try? contact.isKeyAvailable(CNContactNoteKey)) == true ? contact.note : ""

        return ContactRecord(
            hit: hit,
            searchable: (names + work + phones + emails + addresses + [note]).filter { !$0.isEmpty },
            phoneDigits: phones.map { $0.filter(\.isNumber) }.filter { !$0.isEmpty },
            nameFields: names,
            workFields: work,
            hasNote: !note.isEmpty
        )
    }

    /// The name Contacts itself would show. A card marked as a company is filed under the company
    /// name even when it has a person's name on it too.
    static func displayName(for contact: CNContact) -> String {
        if contact.contactType == .organization, !contact.organizationName.isEmpty {
            return contact.organizationName
        }
        let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        return [formatted, contact.organizationName, contact.nickname]
            .first { !$0.isEmpty } ?? "No name"
    }
}
