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

    /// Every contact, as a list we can search ourselves.
    ///
    /// Apple's own `predicateForContacts(matchingName:)` was the obvious route and it is wrong in
    /// both directions: searching "Jose" returned Joan, John and Joyce — it matches names that
    /// merely sound or start alike — while missing "Hernandez Jose" and "Sabutis Joseph"
    /// altogether. Reading the contacts once and matching them here is both correct and faster,
    /// and it is the same principle as the rest of Scout: own the matching.
    public func loadAll() -> [ContactHit] {
        guard access == .allowed else { return [] }

        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch())
        request.unifyResults = true
        request.sortOrder = .givenName

        var hits: [ContactHit] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            hits.append(Self.hit(from: contact))
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
