//
//  ViewController.swift
//  MuseStatsIosSwift
//
//  Created by Gair Shields on 2024-02-23.
//

import UIKit

class ViewController: UIViewController, IXNLogListener, UIPickerViewDataSource, UIPickerViewDelegate {
    var museManager: IXNMuseManager?
    var museListener: IXNMuseListener?
    var dataListener: IXNMuseDataListener?
    var connectionListener: IXNMuseConnectionListener?
    var logManager: IXNLogManager?
    var museList: [String] = []
    var museMap = [String: IXNMuse]()

    @IBOutlet weak var graphView: GraphView!
    @IBOutlet weak var textView: UITextView!
    @IBOutlet weak var buttonDisconnect: UIButton!
    @IBOutlet weak var buttonConnect: UIButton!
    @IBOutlet weak var buttonScan: UIButton!
    @IBOutlet weak var musePicker: UIPickerView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.musePicker.dataSource = self
        self.musePicker.delegate = self
        self.logManager = IXNLogManager.instance()
        self.logManager?.setLogListener(self)
        self.museManager = IXNMuseManagerIos()
        self.museListener = MuseListener(parent: self)
        self.dataListener = DataListener(parent: self)
        self.connectionListener = ConnectionListener(parent: self)
        
        self.museManager?.removeFromList(after: 10)
        self.museManager?.setMuseListener(self.museListener)
        self.museManager?.startListening()
        self.textView.isEditable = false
        self.graphView.start()
    }
    
    func museListChanged() {
        museMap.removeAll()
        museList.removeAll()
        DispatchQueue.main.async {
            if let muses = self.museManager?.getMuses() {
                for muse in muses {
                    self.museMap[muse.getName()] = muse
                    self.museList.append(muse.getName())
                    self.log(message: "Found \(muse.getName()) with ID: \(muse.getMacAddress())")
                }
                self.musePicker.reloadAllComponents()
            }
        }
    }
    
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }
    
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return self.museList.count
    }
    
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return self.museList[row]
    }
    
    func getSelectedItem(picker: UIPickerView) -> String? {
        if self.museList.isEmpty {
            return nil
        }
        let selectedRow = picker.selectedRow(inComponent: 0)
        return self.museList[selectedRow]
    }
    
    @IBAction func onScanClick(_ sender: Any) {
        self.museManager?.stopListening()
        self.museManager?.startListening()
    }
    
    @IBAction func onConnectClick(_ sender: Any) {
        if let m = self.getSelectedItem(picker: self.musePicker) {
            if let muse = self.museMap[m] {
                if muse.getConnectionState() == .disconnected {
                    self.museManager?.stopListening()
                    muse.unregisterAllListeners()
                    muse.register(self.connectionListener)
                    muse.register(self.dataListener, type: .eeg)
                    muse.setPreset(IXNMusePreset.preset21) // See documentation on presets
                    
                    // you can choose to use the internal async loop or define your own
                    // self.runAsynchronously(muse: muse)
                    muse.runAsynchronously()
                }
            }
        }
    }
    
    @IBAction func onDisconnectClick(_ sender: Any) {
        if let muses = self.museManager?.getMuses() {
            for muse in muses {
                if muse.getConnectionState() == .connected {
                    muse.disconnect()
                }
            }
        }
    }
    
    func runAsynchronously(muse: IXNMuse) {
        let TickIntervalSecs = 0.02
        muse.connect()
        DispatchQueue.global().async {
            while true {
                muse.execute()
                if muse.getConnectionState() != .disconnected {
                    Thread.sleep(forTimeInterval: TickIntervalSecs)
                }
                else {
                    self.log(message: "Detected disconnected state... stopping async execution")
                    break
                }
            }
        }
    }
    
    func receive(_ packet: IXNMuseConnectionPacket, muse: IXNMuse?) {
        if packet.previousConnectionState == .connecting && packet.currentConnectionState == .disconnected {
            muse?.unregisterAllListeners()
            log(message: "\(muse?.getName() ?? "") disconnected")
            self.museManager?.startListening()
        }
        if packet.previousConnectionState == .connecting && packet.currentConnectionState == .connected {
            log(message: "\(muse?.getName() ?? "") connected")
        }
    }
    
    func receive(_ packet: IXNMuseDataPacket?, muse: IXNMuse?) {
        if packet != nil && packet!.packetType() == .eeg {
            self.graphView.addPoint(packet: packet!)
        }
    }
    
    func receiveLog(_ log: IXNLogPacket) {
        DispatchQueue.main.async {
            let attr: [NSAttributedString.Key: Any] = [
                .foregroundColor: self.textView.textColor!,
            ]
            self.textView.textStorage.insert(NSAttributedString(string: "\(log.message)\n", attributes: attr), at: 0)
        }
    }
    
    func log(message: String) {
        self.logManager?.writeLog(IXNSeverity.sevDebug, raw: false, tag: "", message: message)
    }
    
    deinit {
        self.graphView?.stop()
        self.museManager?.stopListening()
        if let muses = self.museManager?.getMuses() {
            for muse in muses {
                muse.unregisterAllListeners()
                if muse.getConnectionState() == .connected {
                    muse.disconnect()
                }
            }
        }
    }
}

class MuseListener: IXNMuseListener {
    var parent: ViewController
    
    init(parent: ViewController){
        self.parent = parent
    }
    
    func museListChanged() {
        self.parent.museListChanged()
    }
}

class ConnectionListener: IXNMuseConnectionListener {
    var parent: ViewController
    
    init(parent: ViewController){
        self.parent = parent
    }
    
    func receive(_ packet: IXNMuseConnectionPacket, muse: IXNMuse?) {
        parent.receive(packet, muse: muse)
    }
}

class DataListener: IXNMuseDataListener {
    var parent: ViewController
    
    init(parent: ViewController){
        self.parent = parent
    }
    
    func receive(_ packet: IXNMuseDataPacket?, muse: IXNMuse?) {
        parent.receive(packet, muse: muse)
    }
    
    func receive(_ packet: IXNMuseArtifactPacket, muse: IXNMuse?) {
    }
}
