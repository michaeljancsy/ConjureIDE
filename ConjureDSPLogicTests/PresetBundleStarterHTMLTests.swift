import Foundation
import Testing

struct PresetBundleStarterHTMLTests {

    @Test func starterHTMLEmitsLayoutContainer() {
        let html = PresetBundle.starterIndexHTML()
        #expect(html.contains("class=\"conjure-ui\""),
                "Starter HTML must wrap controls in a .conjure-ui container")
        #expect(html.contains(".conjure-ui {"),
                "Starter HTML must define a .conjure-ui rule")
        #expect(html.contains("flex-direction: column"),
                "Starter HTML's container should stack controls vertically")
        #expect(html.contains("gap: 12px"),
                "Starter HTML's container should give controls breathing room")
        #expect(html.contains("padding: 12px"),
                "Starter HTML's container should pad away from window edges")
    }

    @Test func starterHTMLEmitsBaselineMinSizes() {
        let html = PresetBundle.starterIndexHTML()
        #expect(html.contains("cdp-slider { min-height: 24px; min-width: 100px; }"),
                "cdp-slider min-size baseline missing — layout-density smoke test will fail")
        #expect(html.contains("cdp-knob"),
                "cdp-knob baseline missing")
        #expect(html.contains("min-width: 40px"),
                "cdp-knob min-width baseline missing")
        #expect(html.contains("cdp-xy"),
                "cdp-xy baseline missing")
        #expect(html.contains("min-width: 80px"),
                "cdp-xy / cdp-choice min-width baseline missing")
        #expect(html.contains("cdp-toggle"),
                "cdp-toggle baseline missing")
        #expect(html.contains("cdp-choice"),
                "cdp-choice baseline missing")
    }
}
