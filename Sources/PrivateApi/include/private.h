#ifndef private_header_h
#define private_header_h

#import <ApplicationServices/ApplicationServices.h>

// Potential alternative 1?
// func allWindowsOnCurrentMacOsSpace() {
//     let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
//     let windowsListInfo = CGWindowListCopyWindowInfo(options, CGWindowID(0))
//     let infoList = windowsListInfo as! [[String:Any]]
//     let windows = infoList.filter { $0["kCGWindowLayer"] as! Int == 0 }
//     print(windows.count)
//     for window in windows {
//             print(window)
//             print("Name: \(window["kCGWindowOwnerName"].unsafelyUnwrapped)")
//             print("PID: \(window["kCGWindowOwnerPID"].unsafelyUnwrapped)")
//             print("window ID: \(window["kCGWindowNumber"])")
//             print("---")
//     }
// }
//
// Alternative 2:
// @_silgen_name("_AXUIElementGetWindow")
// @discardableResult
// func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ id: inout CGWindowID) -> AXError
AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

// The window server's built-in hotkeys, such as the Cmd+Tab app switcher (1) and its Shift twin (2).
// The switch lasts for the login session, not for the life of the process that flipped it
CGError CGSSetSymbolicHotKeyEnabled(int hotKey, bool isEnabled);
bool CGSIsSymbolicHotKeyEnabled(int hotKey);

#endif
