//
//  PaddleCheckoutManager.swift
//  ConjureDSP
//
//  Manages checkout flow in the host app.
//  Users subscribe via the website; this class handles the web redirect
//  and can be extended for Paddle Mac SDK integration in the future.
//

import AppKit
import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PaddleCheckout")

@MainActor
class PaddleCheckoutManager: ObservableObject {
    @Published var isCheckingOut = false
    @Published var checkoutError: String?
    @Published var checkoutSuccess = false

    /// Open the web checkout page.
    func startCheckout() {
        isCheckingOut = true
        checkoutError = nil

        if let url = URL(string: "https://conjuredsp.com/subscribe") {
            NSWorkspace.shared.open(url)
        }
        isCheckingOut = false
    }
}
