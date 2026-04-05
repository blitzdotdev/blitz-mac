import Foundation
import Testing
@testable import Blitz

@Test func reviewContactDraftNormalizesPhoneAndDemoFlag() {
    let normalized = MCPExecutor.normalizedReviewContactDraft([
        "contactFirstName": "Taylor",
        "contactPhone": "+1 (650) 555-0100",
        "demoAccountRequired": "yes",
    ])

    #expect(normalized["contactFirstName"] == "Taylor")
    #expect(normalized["contactPhone"] == "+16505550100")
    #expect(normalized["demoAccountRequired"] == "false")
}

@Test func reviewContactMissingRequiredFieldsIncludesPhoneForPartialDraft() {
    let missing = MCPExecutor.missingRequiredReviewContactFields(from: [
        "contactFirstName": "Taylor",
        "contactLastName": "Swift",
        "contactEmail": "taylor@example.com",
    ])

    #expect(missing == ["contactPhone"])
}

@Test func reviewContactMissingRequiredFieldsRequiresDemoCredentialsWhenEnabled() {
    let missing = MCPExecutor.missingRequiredReviewContactFields(from: [
        "contactFirstName": "Taylor",
        "contactLastName": "Swift",
        "contactEmail": "taylor@example.com",
        "contactPhone": "+16505550100",
        "demoAccountRequired": true,
        "demoAccountName": "demo-user",
    ])

    #expect(missing == ["demoAccountPassword"])
}

@Test func reviewContactInitialCreateRequiresFullRequiredBlock() {
    let missing = MCPExecutor.missingRequiredReviewContactFieldsForInitialCreate(
        reviewDetail: nil,
        mergedAttributes: [
            "contactFirstName": "Minjune",
            "contactLastName": "Song",
            "contactEmail": "minjune@example.com",
        ]
    )

    #expect(missing == ["contactPhone"])
}

@Test func reviewContactExistingDetailAllowsSparseUpdates() {
    let missing = MCPExecutor.missingRequiredReviewContactFieldsForInitialCreate(
        reviewDetail: ASCReviewDetail(
            id: "detail-1",
            attributes: .init(
                contactFirstName: "Minjune",
                contactLastName: "Song",
                contactPhone: "+16505550100",
                contactEmail: "minjune@example.com",
                demoAccountRequired: false,
                demoAccountName: nil,
                demoAccountPassword: nil,
                notes: nil
            )
        ),
        mergedAttributes: [
            "notes": "Updated reviewer notes"
        ]
    )

    #expect(missing.isEmpty)
}

@Test func ageRatingStatePayloadPreservesUnsavedNilFields() {
    let payload = MCPExecutor.ageRatingStatePayload(
        ageRating: ASCAgeRatingDeclaration(
            id: "age-rating-1",
            attributes: ASCAgeRatingDeclaration.Attributes(
                alcoholTobaccoOrDrugUseOrReferences: nil,
                contests: nil,
                gambling: nil,
                gamblingSimulated: nil,
                gunsOrOtherWeapons: nil,
                horrorOrFearThemes: nil,
                matureOrSuggestiveThemes: nil,
                medicalOrTreatmentInformation: nil,
                messagingAndChat: nil,
                profanityOrCrudeHumor: nil,
                sexualContentGraphicAndNudity: nil,
                sexualContentOrNudity: nil,
                unrestrictedWebAccess: nil,
                userGeneratedContent: nil,
                violenceCartoonOrFantasy: nil,
                violenceRealistic: nil,
                violenceRealisticProlongedGraphicOrSadistic: nil,
                advertising: nil,
                lootBox: nil,
                healthOrWellnessTopics: nil,
                parentalControls: nil,
                ageAssurance: nil
            )
        ),
        isSaved: false,
        pendingDraft: nil
    )

    #expect(payload?["isSaved"] as? Bool == false)
    #expect((payload?["gambling"] as? NSNull) != nil)
    #expect((payload?["violenceRealistic"] as? NSNull) != nil)
    let missing = payload?["missingRequired"] as? [String]
    #expect(missing?.contains("gambling") == true)
    #expect(missing?.contains("violenceRealistic") == true)
}

@Test func reviewContactStatePayloadShowsPendingDraftState() {
    let payload = MCPExecutor.reviewContactStatePayload(
        reviewDetail: nil,
        pendingDraft: [
            "contactFirstName": "Taylor",
            "contactLastName": "Swift",
            "contactEmail": "taylor@example.com",
        ]
    )

    #expect(payload?["contactFirstName"] as? String == "Taylor")
    #expect(payload?["contactLastName"] as? String == "Swift")
    #expect(payload?["contactEmail"] as? String == "taylor@example.com")
    #expect(payload?["savedToASC"] as? Bool == false)
    #expect(payload?["hasPendingChanges"] as? Bool == true)
    #expect(payload?["missingRequired"] as? [String] == ["contactPhone"])
    #expect(
        Set(payload?["missingRequiredPersisted"] as? [String] ?? [])
            == Set(["contactFirstName", "contactLastName", "contactEmail", "contactPhone"])
    )
    let persisted = payload?["persisted"] as? [String: Any]
    #expect(persisted?["contactFirstName"] as? String == "")
    #expect(persisted?["contactEmail"] as? String == "")
}

@Test func overviewSubmissionReadinessPayloadOverlaysPendingReviewDrafts() {
    let readiness = SubmissionReadiness(fields: [
        .init(label: "Review Contact First Name", value: nil),
        .init(label: "Review Contact Last Name", value: nil),
        .init(label: "Review Contact Email", value: nil),
        .init(label: "Review Contact Phone", value: nil),
    ])

    let payload = MCPExecutor.overviewSubmissionReadinessPayload(
        readiness: readiness,
        reviewDetail: nil,
        pendingFormValues: [
            "review.contact": [
                "contactFirstName": "Taylor",
                "contactLastName": "Swift",
                "contactEmail": "taylor@example.com",
            ]
        ]
    )

    let fields = payload["fields"] as? [[String: Any]]
    let firstNameField = fields?.first { $0["label"] as? String == "Review Contact First Name" }

    #expect(firstNameField?["value"] as? String == "Taylor")
    #expect(firstNameField?["source"] as? String == "draft")
    #expect(firstNameField?["savedToASC"] as? Bool == false)
    #expect(firstNameField?["filled"] as? Bool == false)
    #expect(firstNameField?["filledConsideringDrafts"] as? Bool == true)
    #expect(Set(payload["missingRequired"] as? [String] ?? []).count == 4)
    #expect(Set(payload["missingRequiredPersisted"] as? [String] ?? []).count == 4)
    #expect(payload["missingRequiredConsideringDrafts"] as? [String] == ["Review Contact Phone"])
}

@MainActor
@Test func screenshotSaveDisplayTypesIncludeAllStagedFamiliesByDefault() {
    let manager = ASCManager()
    let locale = "en-US"
    let stagedSlot = TrackSlot(
        id: "local-shot-1",
        localPath: "/tmp/local-shot-1.png",
        localImage: nil,
        ascScreenshot: nil,
        isFromASC: false
    )

    manager.trackSlots[manager.screenshotTrackKey(displayType: "APP_IPHONE_67", locale: locale)] =
        [stagedSlot] + Array(repeating: nil, count: 9)
    manager.trackSlots[manager.screenshotTrackKey(displayType: "APP_IPAD_PRO_3GEN_129", locale: locale)] =
        [stagedSlot] + Array(repeating: nil, count: 9)

    let displayTypes = MCPExecutor.screenshotSaveDisplayTypes(
        requestedDisplayType: nil,
        locale: locale,
        projectDisplayTypes: ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"],
        asc: manager
    )

    #expect(displayTypes == ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"])
}
