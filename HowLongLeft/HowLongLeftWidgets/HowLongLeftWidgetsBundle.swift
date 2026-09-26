//
//  HowLongLeftWidgetsBundle.swift
//  HowLongLeftWidgets
//
//  Created by Ryan on 26/9/2026.
//

import WidgetKit
import HLLKit
import SwiftUI

@main
struct HowLongLeftWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HLLWidget(kind: "HowLongLeftWidgets", contextID: "widget.default",
                  groupIdentifier: "group.com.ryan.HowLongLeft",
                  cloudContainerIdentifier: "iCloud.com.ryan.HowLongLeft",
                  families: [.systemSmall, .systemMedium, .systemLarge,
                             .accessoryInline, .accessoryCircular, .accessoryRectangular])
        HLLLiveActivityWidget()
    }
}
