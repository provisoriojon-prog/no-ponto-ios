import XCTest

final class NoPontoUITests: XCTestCase {
    private var app: XCUIApplication!
    private var suggestions: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'route-row-'")) }
    private var savedRoutes: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-route-'")) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-state"]
        app.launch()
        XCTAssertTrue(app.buttons["search-button"].waitForExistence(timeout: 30))
        waitForCatalog()
    }

    func testMinimalSearchSavedRoutesAndPersistence() throws {
        XCTAssertEqual(savedRoutes.count, 0)
        XCTAssertFalse(app.buttons["line-detail-button"].exists)
        XCTAssertFalse(app.staticTexts["No Ponto"].exists, "A abertura deve ser o mapa sem cabeçalho")
        XCTAssertFalse(app.staticTexts["Seu próximo ônibus, aqui."].exists)
        capture("01-mapa-limpo")

        openSearch()
        let search = app.textFields["route-search-field"]
        XCTAssertEqual(suggestions.count, 0, "Busca vazia não lista o catálogo")
        search.typeText("3")
        XCTAssertEqual(suggestions.count, 0, "Um dígito não deve mostrar centenas de linhas")
        search.typeText("9")
        XCTAssertTrue(suggestions.firstMatch.waitForExistence(timeout: 15))
        XCTAssertLessThanOrEqual(suggestions.count, 8)
        capture("02-sugestoes-39")
        search.typeText("7")
        XCTAssertTrue(routeSuggestion("397").waitForExistence(timeout: 10))
        XCTAssertTrue(routeSuggestion("SN397").waitForExistence(timeout: 10))
        XCTAssertTrue(routeSuggestion("SR397").waitForExistence(timeout: 10))
        let threeSuggestions = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in self?.suggestions.count == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [threeSuggestions], timeout: 10), .completed)
        capture("03-sugestoes-397")
        routeSuggestion("397").tap()
        waitUntilGone(search)
        XCTAssertTrue(savedRoute("397").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["choose-pattern-button"].exists, "Adicionar linha fecha a busca, sem abrir detalhe")
        XCTAssertFalse(app.buttons["line-detail-button"].exists, "Não há painel permanente após adicionar linha")

        addRoute("369")
        addRoute("SR397")
        XCTAssertEqual(savedRoutes.count, 3)
        capture("04-mapa-tres-linhas")
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(savedRoute("369").waitForExistence(timeout: 30))
        XCTAssertTrue(savedRoute("397").exists)
        XCTAssertTrue(savedRoute("SR397").exists)
        XCTAssertEqual(savedRoutes.count, 3, "As linhas do mapa devem persistir sem salvar um ponto")
        XCTAssertFalse(app.buttons["line-detail-button"].exists)

        savedRoute("369").tap()
        capture("linha-369-primeiro-toque")
        let active = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            self?.savedRoute("369").value as? String == "ativa"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 10), .completed, "O toque deve ativar a linha 369")
        openContextDetails()
        XCTAssertTrue(app.buttons["choose-stop-button"].waitForExistence(timeout: 10))
        app.buttons["choose-stop-button"].tap()
        let banguStop = app.buttons["stop-4"] // Almeida Pires, official 369 stop near the three demo routes.
        XCTAssertTrue(banguStop.waitForExistence(timeout: 10))
        if !banguStop.isHittable { app.swipeUp() }
        banguStop.tap()
        app.buttons["show-stop-map-button"].tap()
        XCTAssertTrue(app.buttons["Fechar informação"].waitForExistence(timeout: 10))
        app.buttons["Fechar informação"].tap()
        capture("05-mapa-local-tres-linhas")
        savedRoute("369").tap()
        openContextDetails()
        XCTAssertTrue(app.buttons["choose-pattern-button"].waitForExistence(timeout: 10))
        app.buttons["choose-pattern-button"].tap()
        let otherDirection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pattern-' AND value == 'sentido-1'")).firstMatch
        XCTAssertTrue(otherDirection.waitForExistence(timeout: 10))
        if !otherDirection.isHittable { app.swipeUp() }
        otherDirection.tap()
        app.buttons["choose-stop-button"].tap()
        let stop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stop-'")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(app.buttons["favorite-save-button"].waitForExistence(timeout: 10))
        capture("06-detalhes-sob-toque")
        app.buttons["favorite-save-button"].tap()
        let nameField = app.textFields["favorite-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        let favoriteName = try XCTUnwrap(nameField.value as? String)
        app.buttons["confirm-favorite-button"].tap()
        XCTAssertTrue(app.buttons["choose-stop-button"].waitForExistence(timeout: 10))
        app.buttons["Fechar"].firstMatch.tap()
        app.buttons["settings-menu"].tap()
        app.buttons["Favoritos de embarque"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[favoriteName].waitForExistence(timeout: 10), "Favoritos continuam acessíveis pelo menu secundário")
        app.buttons["Fechar"].firstMatch.tap()
        app.buttons["saved-routes-menu"].tap()
        app.buttons["Remover todas"].firstMatch.tap()
        waitUntilGone(savedRoute("397"))
        XCTAssertEqual(savedRoutes.count, 0)
        XCTAssertFalse(app.buttons["line-detail-button"].exists)
        capture("07-mapa-limpo-apos-remover")
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["search-button"].waitForExistence(timeout: 30))
        waitForCatalog()
        XCTAssertEqual(savedRoutes.count, 0, "Remover todas deve persistir no próximo lançamento")
    }

    func testLocationDeniedLeavesMapCleanAndSearchAvailable() throws {
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
        let explanation = app.alerts["Localização"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 15))
        explanation.buttons["OK"].tap()
        waitUntilGone(explanation)
        XCTAssertFalse(app.staticTexts["location-message"].exists, "Recusa não deixa painel cobrindo o mapa")
        XCTAssertEqual(savedRoutes.count, 0)
        openSearch()
        XCTAssertEqual(suggestions.count, 0)
    }

    private func routeSuggestion(_ number: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'route-row-' AND label BEGINSWITH %@", "Linha \(number),")).firstMatch
    }

    private func savedRoute(_ number: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-route-' AND label == %@", "Linha \(number)")).firstMatch
    }

    private func openSearch() {
        app.buttons["search-button"].tap()
        let field = app.textFields["route-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
    }

    private func addRoute(_ number: String) {
        openSearch()
        let field = app.textFields["route-search-field"]
        field.typeText(number)
        let suggestion = routeSuggestion(number)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15))
        suggestion.tap()
        waitUntilGone(field)
        XCTAssertTrue(savedRoute(number).waitForExistence(timeout: 10))
    }

    private func waitUntilGone(_ element: XCUIElement) {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !element.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 15), .completed)
    }

    private func openContextDetails() {
        let button = app.buttons["line-detail-button"]
        let exists = button.waitForExistence(timeout: 10)
        capture("contexto-apos-toque-na-linha")
        if !exists {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "contexto-hierarquia-acessibilidade"
            tree.lifetime = .keepAlways
            add(tree)
            print("CONTEXT_ACCESSIBILITY_DIAGNOSTIC\n\(app.debugDescription)")
        }
        XCTAssertTrue(exists, "O toque na linha deve revelar o cartão contextual acessível")
        XCTAssertTrue(button.isHittable, "O cartão contextual deve ser tocável")
        button.tap()
    }

    private func waitForCatalog() {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            self?.app.buttons["search-button"].value as? String == "pronto"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
