//
//  ExportAUViewController.swift
//  ConjureDSPExportAUTemplateExtension
//

import CoreAudioKit
import SwiftUI

@MainActor
public class ExportAUViewController: AUViewController, AUAudioUnitFactory {
    var audioUnit: AUAudioUnit?
    private var hostingView: NSHostingView<ExportAUMainView>?
    private var parameterState: ExportParameterState?

    public override var preferredMinimumSize: NSSize {
        NSSize(width: 300, height: 200)
    }

    public override var preferredMaximumSize: NSSize {
        NSSize(width: 800, height: 600)
    }

    public override func loadView() {
        self.view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 400, height: 300)))
        self.preferredContentSize = NSSize(width: 400, height: 300)
    }

    nonisolated public func createAudioUnit(
        with componentDescription: AudioComponentDescription
    ) throws -> AUAudioUnit {
        return try DispatchQueue.main.sync {
            let au = try ExportAUAudioUnit(
                componentDescription: componentDescription, options: []
            )
            audioUnit = au
            return au
        }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        guard let audioUnit else { return }
        if hostingView == nil {
            DispatchQueue.main.async { [weak self] in
                self?.configureSwiftUIView(audioUnit: audioUnit)
            }
        }
    }

    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        guard let au = audioUnit as? ExportAUAudioUnit else { return }

        let bundle = Bundle(for: type(of: self))
        let config = RuntimeConfig.load(from: bundle)

        let ps = ExportParameterState(
            paramCount: config?.effectiveParamCount ?? 8,
            paramMetadata: config?.paramMetadata
        )
        self.parameterState = ps
        if let tree = au.parameterTree {
            ps.attach(to: tree)
        }

        let content = ExportAUMainView(
            parameterState: ps,
            config: config,
            pythonRuntimeMissing: au.pythonRuntimeMissing
        )
        let hv = NSHostingView(rootView: content)
        hv.sizingOptions = []
        hv.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(hv)
        NSLayoutConstraint.activate([
            hv.topAnchor.constraint(equalTo: self.view.topAnchor),
            hv.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hv.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        hostingView = hv
    }
}
