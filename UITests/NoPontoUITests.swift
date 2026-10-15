import XCTest

final class NoPontoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-state"]
        app.launch()
        XCTAssertTrue(app.buttons["search-button"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["demo-banner"].firstMatch.waitForExistence(timeout: 30))
    }

    func testSearchDirectionStopAndPersistentFavorite() throws {
        XCTAssertTrue(app.buttons["line-detail-button"].waitForExistence(timeout: 20))
        capture("01-mapa")
        app.buttons["line-detail-button"].tap()
        XCTAssertTrue(app.buttons["choose-stop-button"].waitForExistence(timeout: 10))
        capture("01b-chegadas-demonstracao")
        app.buttons["Fechar"].firstMatch.tap()
        app.buttons["search-button"].tap()
        let search = app.textFields["route-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("397")
        let suffix = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'route-row-' AND label CONTAINS 'SR397'")).firstMatch
        XCTAssertTrue(suffix.waitForExistence(timeout: 10), "A busca deve preservar variantes com prefixos, como SR397")
        capture("02-busca-com-variantes")
        app.buttons["Limpar busca"].tap()
        search.tap()
        search.typeText("369")
        let route = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'route-row-'")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        route.tap()
        XCTAssertTrue(app.buttons["choose-pattern-button"].waitForExistence(timeout: 10))
        app.buttons["choose-pattern-button"].tap()
        let otherDirection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pattern-' AND value == 'sentido-1'")).firstMatch
        XCTAssertTrue(otherDirection.waitForExistence(timeout: 10))
        if !otherDirection.isHittable { app.swipeUp() }
        otherDirection.tap()
        XCTAssertTrue(app.buttons["choose-stop-button"].waitForExistence(timeout: 10))
        app.buttons["choose-stop-button"].tap()
        let stop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stop-'")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(app.buttons["favorite-save-button"].waitForExistence(timeout: 10))
        capture("03-ponto-e-sentido")
        app.buttons["favorite-save-button"].tap()
        let favoriteNameField = app.textFields["favorite-name-field"]
        XCTAssertTrue(favoriteNameField.waitForExistence(timeout: 10))
        let favoriteName = try XCTUnwrap(favoriteNameField.value as? String)
        app.buttons["confirm-favorite-button"].tap()
        XCTAssertTrue(app.buttons["choose-stop-button"].waitForExistence(timeout: 10))
        app.buttons["Fechar"].firstMatch.tap()
        XCTAssertTrue(app.buttons["favorites-button"].waitForExistence(timeout: 10))
        app.buttons["favorites-button"].tap()
        XCTAssertTrue(app.staticTexts[favoriteName].waitForExistence(timeout: 10))
        capture("04-favoritos")
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["favorites-button"].waitForExistence(timeout: 20))
        app.buttons["favorites-button"].tap()
        XCTAssertTrue(app.staticTexts[favoriteName].waitForExistence(timeout: 10), "O favorito deve persistir após fechar e abrir o app")
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'favorite-'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
        XCTAssertTrue(app.buttons["favorite-save-button"].waitForExistence(timeout: 10))
    }

    func testLocationDeniedKeepsManualSearchAvailable() throws {
        addUIInterruptionMonitor(withDescription: "Localização") { alert in
            for title in ["Don’t Allow", "Don't Allow", "Não Permitir", "Não permitir"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.buttons["my-location-button"].tap()
        app.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Don’t Allow", "Don't Allow", "Não Permitir", "Não permitir"] {
            if system.alerts.buttons[title].exists { system.alerts.buttons[title].tap(); break }
        }
        XCTAssertTrue(app.staticTexts["location-message"].waitForExistence(timeout: 10), "O app deve explicar a localização indisponível após a recusa")
        XCTAssertTrue(app.buttons["search-button"].waitForExistence(timeout: 10))
        app.buttons["search-button"].tap()
        XCTAssertTrue(app.textFields["route-search-field"].waitForExistence(timeout: 10))
        capture("05-busca-sem-localizacao")
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
