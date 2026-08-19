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

/// The Contacts lane.
///
/// Contacts are their own store with their own permission — nothing to do with Full Disk Access —
/// so this lane can work even when Mail and Messages cannot.
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

    /// Built per call rather than held in a static: `CNKeyDescriptor` predates Sendable, and the
    /// list is three array literals' worth of work.
    private static func keysToFetch() -> [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
    }

    /// Search names, then email addresses, then phone numbers — the three ways anyone looks
    /// someone up. Apple's contact predicates only take one of those at a time, so all three run
    /// and the results are merged.
    public func search(_ query: String, limit: Int = 30) -> [ContactHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, access == .allowed else { return [] }

        let store = CNContactStore()
        var predicates: [NSPredicate] = [CNContact.predicateForContacts(matchingName: trimmed)]

        if trimmed.contains("@") {
            predicates.append(CNContact.predicateForContacts(matchingEmailAddress: trimmed))
        }
        // Only bother with the phone predicate when the query looks like a number.
        if trimmed.contains(where: \.isNumber), !trimmed.contains(where: { $0.isLetter }) {
            let number = CNPhoneNumber(stringValue: trimmed)
            predicates.append(CNContact.predicateForContacts(matching: number))
        }

        var seen: Set<String> = []
        var hits: [ContactHit] = []

        for predicate in predicates {
            let found = (try? store.unifiedContacts(matching: predicate, keysToFetch: Self.keysToFetch())) ?? []
            for contact in found where seen.insert(contact.identifier).inserted {
                hits.append(Self.hit(from: contact))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    private static func hit(from contact: CNContact) -> ContactHit {
        let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        let name = [formatted, contact.organizationName]
            .first { !$0.isEmpty } ?? "No name"

        return ContactHit(
            identifier: contact.identifier,
            name: name,
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            phone: contact.phoneNumbers.first?.value.stringValue,
            email: contact.emailAddresses.first?.value as String?
        )
    }
}
