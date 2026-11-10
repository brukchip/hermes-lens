import Contacts
import ContactsUI
import HermesLensCore
import SwiftUI

/// Apple's new-contact sheet, prefilled from a card Luna read. The user checks it and
/// saves with Done in Apple's own UI; the app never writes Contacts itself.
struct ContactEditorSheet: UIViewControllerRepresentable {
    let draft: LunaContactDraft
    let finished: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = CNContactViewController(forNewContact: Self.contact(from: draft))
        editor.delegate = context.coordinator
        return UINavigationController(rootViewController: editor)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    static func contact(from draft: LunaContactDraft) -> CNMutableContact {
        let contact = CNMutableContact()
        if let name = draft.name {
            let parts = PersonNameComponentsFormatter().personNameComponents(from: name)
            contact.givenName = parts?.givenName ?? name
            contact.middleName = parts?.middleName ?? ""
            contact.familyName = parts?.familyName ?? ""
        }
        contact.organizationName = draft.company ?? ""
        contact.jobTitle = draft.jobTitle ?? ""
        if let phone = draft.phone {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = draft.email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
        }
        if let website = draft.website {
            contact.urlAddresses = [CNLabeledValue(label: CNLabelWork, value: website as NSString)]
        }
        if let address = draft.address {
            let postal = CNMutablePostalAddress()
            postal.street = address
            contact.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: postal)]
        }
        return contact
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency CNContactViewControllerDelegate {
        let finished: @MainActor (Bool) -> Void
        init(finished: @escaping @MainActor (Bool) -> Void) { self.finished = finished }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            finished(contact != nil)
        }
    }
}
