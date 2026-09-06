import Testing
@testable import ReolinkVideo

@Suite("TLS question buttons")
struct CertificateTrustTests {
    @Test("The permanent accept wins over the temporary one")
    func prefersPermanent() {
        #expect(CertificateTrust.acceptButton("Accept 24 hours", "Accept permanently") == 2)
        #expect(CertificateTrust.acceptButton("Accept permanently", "Accept 24 hours") == 1)
    }

    @Test("Viewing the certificate is never an answer")
    func rejectsViewCertificate() {
        // libvlc's first dialog offers this alone. Answering it loops.
        #expect(CertificateTrust.acceptButton("View certificate", nil) == nil)
        #expect(CertificateTrust.acceptButton("View certificate", "Accept 24 hours") == 2)
    }

    @Test("An abort or cancel label is never an answer")
    func rejectsAbort() {
        #expect(CertificateTrust.acceptButton("Abort", nil) == nil)
        #expect(CertificateTrust.acceptButton("Cancel", "Abort") == nil)
    }

    @Test("An unlabelled pair falls back to the later button")
    func fallsBackToLast() {
        #expect(CertificateTrust.acceptButton("Continue", "Proceed") == 2)
        #expect(CertificateTrust.acceptButton("Continue", nil) == 1)
        #expect(CertificateTrust.acceptButton(nil, nil) == nil)
        #expect(CertificateTrust.acceptButton("", "") == nil)
    }
}
