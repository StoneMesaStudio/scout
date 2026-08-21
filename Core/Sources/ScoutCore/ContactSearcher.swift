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
    /// Just the digits of every number, so "6522909" finds "1 (505) 652-2909".
    public let phoneDigits: [String]

    public init(hit: ContactHit, searchable: [String], phoneDigits: [String]) {
        self.hit = hit
        self.searchable = searchable
        self.phoneDigits = phoneDigits
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

        // Note is fetched but not searched: it is where people keep things they would not expect
        // a search box to surface.
        let names = [
            contact.givenName, contact.middleName, contact.familyName,
            contact.previousFamilyName, contact.nickname,
            contact.organizationName, contact.departmentName, contact.jobTitle,
        ]

        let hit = ContactHit(
            identifier: contact.identifier,
            name: displayName(for: contact),
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            phone: phones.first,
            email: emails.first
        )

        return ContactRecord(
            hit: hit,
            searchable: (names + phones + emails + addresses).filter { !$0.isEmpty },
            phoneDigits: phones.map { $0.filter(\.isNumber) }.filter { !$0.isEmpty }
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
