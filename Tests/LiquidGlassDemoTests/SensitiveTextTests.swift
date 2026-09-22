import Testing
@testable import LiquidGlassDemo

@Suite struct SensitiveTextTests {
    @Test func masksCardPhoneAndEmailWhileKeepingSearchableContext() {
        #expect(
            SensitiveText.redact("Card 4514 6176 9957 3715")
                == "Card •••• •••• •••• 3715"
        )
        #expect(SensitiveText.redact("Call 13812345678") == "Call 1•• •••• 5678")
        #expect(SensitiveText.redact("Mail wang@example.com") == "Mail w•••@example.com")
        #expect(SensitiveText.redact("Captured Sep 21, 2026") == "Captured Sep 21, 2026")
    }
}
