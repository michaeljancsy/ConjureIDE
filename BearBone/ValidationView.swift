//
//  ValidationView.swift
//  BearBone
//
//  Created by Michael Jancsy on 2/25/26.
//

#if DEBUG
import SwiftUI
import AudioToolbox

struct ValidationView: View {
    var hostModel: AudioUnitHostModel
    @Binding var isSheetPresented: Bool
    
    
    var body: some View {
        if let validationResult = hostModel.validationResult {
            Text(validationResult == .passed ? "Validation Passed" : "Validation Failed")
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(validationResult == .passed ? Color.green : Color.red)
                )
                .foregroundColor(.black)
                .onTapGesture {
                    isSheetPresented.toggle()
                }
                .sheet(isPresented: $isSheetPresented) {
                    VStack {
                        Text("Close")
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.gray.opacity(0.2))
                            )
                            .foregroundColor(.primary)
                            .onTapGesture {
                                isSheetPresented.toggle()
                            }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if let output = hostModel.currentValidationData {
                                    Text(output)
                                        .foregroundColor(.primary)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(8)
                                        .lineLimit(nil)
                                        .frame(maxWidth: .infinity)
                                        .textSelection(.enabled)
                                } else {
                                    Text("Validation probably crashed")
                                }
                            }
                            .padding()
                        }
                    }
                    .padding()
                }
        }
    }
}
#endif
