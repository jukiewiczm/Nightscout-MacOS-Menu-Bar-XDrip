//
//  NightscoutMenuBar.swift
//  NightscoutMenuBar
//
//  Created by adam.d on 27/6/2022.
//

import SwiftUI
import Foundation
import Cocoa
import Combine
import Charts
import AppKit

private let store = EntriesStore()
let nsmodel = NightscoutModel()
private let otherinfo = OtherInfoModel()
var screenIsLocked = false
let notchAlertTimeIntervalInMinutes: TimeInterval = 15
var lastNotchAlertTimestamp: TimeInterval = 0
var dockIconManager = DockIconManager.shared

@main
struct NightscoutMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = SettingsModel()
    
    var body: some Scene {
        Settings {
            SettingsView()
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    print("inactive")
                    settings.glUrlTemp = settings.glUrl
                    settings.glIsEdit = false
                    settings.glTokenTemp = settings.glToken
                    settings.glIsEditToken = false
                }
                .environmentObject(settings)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        dockIconManager.hideDock()
        getEntries()
        setupRefreshTimer()
    }

    
    func applicationDidBecomeActive(_ notification: Notification) {
        dockIconManager.dockWasClicked()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            dockIconManager.dockWasClicked()
        }

        return true
    }
    
    private func setupRefreshTimer() {
        let refreshInterval: TimeInterval = 60
        Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in getEntries() }
    }
    
}

class NightscoutModel: ObservableObject {
    private let menu = MainMenu()
    var statusItem: MenuBarWidgetProtocol

    init() {
        @AppStorage("useLegacyStatusItem") var useLegacyStatusItem = false
        self.statusItem = MenuBarWidgetFactory.makeStatusItem(type: useLegacyStatusItem ? .legacy : .normal)
        startVisibilityChecks()
    }

    func updateDisplay(message: String ,extraMessage: String?) {
        @AppStorage("useLegacyStatusItem") var useLegacyStatusItem = false
        nsmodel.statusItem.updateDisplay(message: message, store: store, extraMessage: extraMessage)
    }
    
    func emptyHistoryMenu() {
        store.entries.removeAll()
        nsmodel.statusItem.emptyHistoryMenu(entries: [String]())
    }
    
    private func startVisibilityChecks() {
        
        let dnc = DistributedNotificationCenter.default()

        dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                                       object: nil, queue: .main) { _ in
            print("Screen Locked")
            screenIsLocked = true
        }

        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                         object: nil, queue: .main) { _ in
            print("Screen Unlocked")
            screenIsLocked = false
        }
    }
    
    
}

extension NSScreen {
    var hasTopNotchDesign: Bool {
        guard #available(macOS 12, *) else { return false }
        return safeAreaInsets.top != 0
    }
}

func reset() {
    @AppStorage("useLegacyStatusItem") var useLegacyStatusItem = false
    destroyMenuItem()
    nsmodel.statusItem = MenuBarWidgetFactory.makeStatusItem(type: useLegacyStatusItem ? .legacy : .normal)
    getEntries()
}

func addRawEntry(rawEntry: [String: Any]) {
    let bgMg = rawEntry["sgv"] as! Int
    let entry = Entry(
        time: Date(timeIntervalSince1970: (rawEntry["date"] as! Double) / 1000.0),
        bgMg: bgMg,
        bgMmol: helpers().convertbgMgToMmol(bgMg: bgMg),
        direction: rawEntry["direction"] as! String
    )
    store.entries.insert(entry, at: 0)
}

func destroyMenuItem() {
    nsmodel.statusItem.destroyStatusItem()
}
func getEntries() {
    @AppStorage("nightscoutUrl") var nightscoutUrl = ""
    @AppStorage("accessToken") var accessToken = ""
    @AppStorage("showLoopData") var showLoopData = false
    if (store.entries.isEmpty) {
        nsmodel.updateDisplay(message: "[loading]",extraMessage: "Getting initial entries...")
    }
    if (nightscoutUrl == "") {
        handleNetworkFail(reason: "Add your Nightscout URL in Preferences")
        return
    }
    
    var fullNightscoutUrl = ""
    
    if (accessToken != "") {
        fullNightscoutUrl = nightscoutUrl + "/sgv.json?count=60&token=" + accessToken
    } else {
        fullNightscoutUrl = nightscoutUrl + "/sgv.json?count=60"
    }
    
    if(helpers().isNetworkAvailable() != true) {
        handleNetworkFail(reason: "No network")
        return
    }
    if (isValidURL(url: fullNightscoutUrl) == false) {
        handleNetworkFail(reason: "isValidUrl failed")
        return
    }

    guard let url = URL(string: fullNightscoutUrl) else {
        handleNetworkFail(reason: "create URL failed")
        return
        
    }

    let urlRequest = URLRequest(url: url)
    
    let dataTask = URLSession(configuration: .ephemeral).dataTask(with: urlRequest) { (data, response, error) in
        if let error = error {
            print("Request error: ", error)
            return
        }
        guard let response = response as? HTTPURLResponse else {
            handleNetworkFail(reason: "not a valid HTTP response")
            return
            
        }
        if response.statusCode == 200 {
            guard let data = data else {
                handleNetworkFail(reason: "no data in response")
                return
            }
            DispatchQueue.main.async {
                store.entries.removeAll()
                do {
                    let entries = try JSONSerialization.jsonObject(with: data, options: []) as! [[String: Any]]
                    entries.forEach({entry in addRawEntry(rawEntry: entry) })
                } catch {
                    print("Failed to parse JSON: \(error)")
                }
                if (store.entries.isEmpty) {
                    handleNetworkFail(reason: "no valid data")
                    return
                }
                nsmodel.statusItem.populateHistoryMenu(store: store)
                if (showLoopData == true) {
                    getProperties()
                }
                
                if (isStaleEntry(entry: store.entries[0], staleThresholdMin: 15)) {
                    nsmodel.updateDisplay(message: "???",extraMessage: "No recent readings from CGM")
                } else {
                    if (showLoopData == true) {
                        nsmodel.updateDisplay(message: bgValueFormatted(entry: store.entries[0]) + " | IOB: " + (otherinfo.loopIob.isEmpty ? "???" : otherinfo.loopIob), extraMessage: nil)
                    } else {
                        nsmodel.updateDisplay(message: bgValueFormatted(entry: store.entries[0]), extraMessage: nil)
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                handleNetworkFail(reason: "response code was " + String(response.statusCode))
            }
        }
    }
    dataTask.resume()
    
    func handleNetworkFail(reason: String) {
        print("Network error source: " + reason)
        if (store.entries.isEmpty || isStaleEntry(entry: store.entries[0], staleThresholdMin: 15)) {
            nsmodel.emptyHistoryMenu()
            nsmodel.updateDisplay(message: "[network]", extraMessage: reason)
        } else {
            nsmodel.statusItem.populateHistoryMenu(store: store)
            nsmodel.updateDisplay(message: bgValueFormatted(entry: store.entries[0]) + "!", extraMessage: "Temporary network failure")
        }
        
    }
    
    func isValidURL(url: String) -> Bool {
        let urlToVal: NSURL? = NSURL(string: url)

        if urlToVal != nil {
            return true
        }
        return false
    }
}


func pumpDataIndicator() -> String {
    return ""
}

func getProperties() {
    @AppStorage("nightscoutUrl") var nightscoutUrl = ""
    @AppStorage("accessToken") var accessToken = ""
    
    var fullNightscoutUrl = ""
    
    if (accessToken != "") {
        fullNightscoutUrl = nightscoutUrl + "/pebble?token=" + accessToken
    } else {
        fullNightscoutUrl = nightscoutUrl + "/pebble"
    }
    
    if (isValidURL(url: fullNightscoutUrl) == false) {
        handleNetworkFail(reason: "isValidUrl failed")
        return
    }
    guard let url = URL(string: fullNightscoutUrl) else {
        handleNetworkFail(reason: "create URL failed")
        return
        
    }
    
    let urlRequest = URLRequest(url: url)
    
    let dataTask = URLSession(configuration: .ephemeral).dataTask(with: urlRequest) { (data, response, error) in
        if let error = error {
            print("Request error: ", error)
            return
        }
        guard let response = response as? HTTPURLResponse else {
            handleNetworkFail(reason: "not a valid HTTP response")
            return
            
        }
        
        if response.statusCode == 200 {
            guard let data = data else {
                handleNetworkFail(reason: "no data in response")
                return
            }
            DispatchQueue.main.async {
                if let json = try! JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] {
                    parseExtraInfo(properties: json)
                }
            }
        } else {
            DispatchQueue.main.async {
                handleNetworkFail(reason: "response code was " + String(response.statusCode))
            }
        }
    }
    dataTask.resume()
    
    func handleNetworkFail(reason: String) {
        print("Network error getting other info: " + reason)
        
    }
    
    func isValidURL(url: String) -> Bool {
        let urlToVal: NSURL? = NSURL(string: url)

        if urlToVal != nil {
            return true
        }
        return false
    }
}

func parseExtraInfo(properties: [String: Any]) {
    //get IOB
    let iob = (properties["bgs"] as! [[String: Any]])[0]["iob"] as! String
    otherinfo.loopIob = iob
    
    //get COB
    if let cob = properties["cob"] as? [String: Any] {
        if let cobDisplay = cob["display"] as? Int {
            otherinfo.loopCob = String(cobDisplay)
        } else if let cobDisplay = cob["display"] as? Double {
            otherinfo.loopCob = String(cobDisplay)
        } else if let cobDisplay = cob["display"] as? String {
            otherinfo.loopCob = cobDisplay
        } else {
            print("cob not found")
        }
    } else {
        print("cob not found")
    }

    //get Pump Info
    if let pump = properties["pump"] as? [String: Any] {
        
        //get device stats
        if let pumpData = pump["data"] as? [String: Any] {
            //clock
            if let pumpDataClock = pumpData["clock"] as? [String: Any] {
                if let pumpDataClockDisplay = pumpDataClock["display"] as? String {
                    otherinfo.pumpAgo = pumpDataClockDisplay
                }
                else {
                    print("pump clock not found")
                }
            }                 else {
                print("pump clock not found")
            }
            //battery
            if let pumpDataBattery = pumpData["battery"] as? [String: Any] {
                if let pumpDataBatteryDisplay = pumpDataBattery["display"] as? String {
                    otherinfo.pumpBatt = pumpDataBatteryDisplay
                } else {
                    print("pump batt not found")
                }
            } else {
                print("pump batt not found")
            }
            //reservoir
            if let pumpDataReservoir = pumpData["reservoir"] as? [String: Any] {
                if let pumpDataReservoirDisplay = pumpDataReservoir["display"] as? String {
                    otherinfo.pumpReservoir = pumpDataReservoirDisplay
                } else {
                    print("pump res not found")
                }
            } else {
                print("pump res not found")
            }
        } else {
            print("pump details not found")
        }
        
        //get loop stats
//        if let pumpLoop = pump["loop"] as? [String: Any] {
//            if let pumpLoopPredicted = pumpLoop["predicted"] as? [String: Any] {
//                if let pumpLoopPredictedValues = pumpLoopPredicted["values"] as? NSArray {
//                    otherinfo.loopPredictions = pumpLoopPredictedValues
//                }
//            }
//        }
    } else {
        print("pump not found")
    }
    if (otherinfo.loopIob.isEmpty || otherinfo.loopCob.isEmpty || otherinfo.pumpAgo.isEmpty || otherinfo.pumpBatt.isEmpty || otherinfo.pumpReservoir.isEmpty) {
        print("Unable to get all loop properties")
    }
    nsmodel.statusItem.updateOtherInfo(otherinfo: otherinfo)
}

func bgValueFormatted(entry: Entry? = nil) -> String {
    @AppStorage("bgUnits") var userPrefBg = "mgdl"
    @AppStorage("showLoopData") var showLoopData = false
    @AppStorage("displayShowUpdateTime") var displayShowUpdateTime = false
    @AppStorage("displayShowBGDifference") var displayShowBGDifference = false
    
    var bgVal = ""
    
    if (userPrefBg == "mmol") {
        bgVal += String(entry!.bgMmol)
    } else {
        bgVal += String(entry!.bgMg)
    }
    switch entry!.direction {
    case "":
        bgVal += ""
    case "NONE":
        bgVal += " →"
    case "Flat":
        bgVal += " →"
    case "FortyFiveDown":
        bgVal += " ➘"
    case "FortyFiveUp":
        bgVal += " ➚"
    case "SingleUp":
        bgVal += " ↑"
    case "DoubleUp":
        bgVal += " ↑↑"
    case "SingleDown":
        bgVal += " ↓"
    case "DoubleDown":
        bgVal += " ↓↓"
    default:
        bgVal += " *"
        print("Unknown direction: " + entry!.direction)
    }
    
    if (displayShowBGDifference == true) {
        
        if (userPrefBg == "mmol") {
            let n = Double(store.entries[0].bgMmol - store.entries[1].bgMmol);
            //Round mmol to 1dp
            bgVal += " " + String(format: "%.1f", n)
        } else {
            bgVal += " " + String(store.entries[0].bgMg - store.entries[1].bgMg)
        }
    }
    
    if (displayShowUpdateTime == true) {
        bgVal += " " + bgMinsAgo(entry: store.entries[0]) + " m"
    }
    return bgVal
}

func bgValueFormattedHistory(entry: Entry? = nil) -> String {
    @AppStorage("bgUnits") var userPrefBg = "mgdl"
    @AppStorage("showLoopData") var showLoopData = false
    
    var bgVal = ""
    
    if (userPrefBg == "mmol") {
        bgVal += String(entry!.bgMmol)
    } else {
        bgVal += String(entry!.bgMg)
    }
    switch entry!.direction {
    case "":
        bgVal += ""
    case "NONE":
        bgVal += " →"
    case "Flat":
        bgVal += " →"
    case "FortyFiveDown":
        bgVal += " ➘"
    case "FortyFiveUp":
        bgVal += " ➚"
    case "SingleUp":
        bgVal += " ↑"
    case "DoubleUp":
        bgVal += " ↑↑"
    case "SingleDown":
        bgVal += " ↓"
    case "DoubleDown":
        bgVal += " ↓↓"
    default:
        bgVal += " *"
        print("Unknown direction: " + entry!.direction)
    }

    return bgVal
}

func bgMinsAgo(entry: Entry? = nil) -> String {
    if (entry == nil) {
        return ""
    }
    
    let fromNow = String(Int(minutesBetweenDates(entry!.time, Date())))
    return fromNow
}

func isStaleEntry(entry: Entry, staleThresholdMin: Int) -> Bool {
    let fromNow = String(Int(minutesBetweenDates(entry.time, Date())))
    if (Int(fromNow)! > staleThresholdMin) {
        return true
    } else {
        return false
    }
}

func minutesBetweenDates(_ oldDate: Date, _ newDate: Date) -> CGFloat {
    
    //get both times sinces refrenced date and divide by 60 to get minutes
    let newDateMinutes = newDate.timeIntervalSinceReferenceDate/60
    let oldDateMinutes = oldDate.timeIntervalSinceReferenceDate/60
    
    //then return the difference
    return CGFloat(newDateMinutes - oldDateMinutes)
}
