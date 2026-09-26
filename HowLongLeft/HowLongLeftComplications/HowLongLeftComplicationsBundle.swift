//
//  HowLongLeftComplicationsBundle.swift
//  HowLongLeftComplications
//
//  Created by Ryan on 26/9/2026.
//

import WidgetKit
import HLLKit
import SwiftUI

@main
struct HowLongLeftComplicationsBundle: WidgetBundle {
    var body: some Widget {
        HLLWidget(kind: "HowLongLeftComplications", contextID: "complication.default",
                  groupIdentifier: "group.com.ryan.HowLongLeft",
                  families: [.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
