//
//  GraphView.swift
//  MuseStatsIosSwift
//
//  Created by Gair Shields on 2024-02-23.
//

import Foundation
import UIKit

struct DataPoint {
    var value: Double
    var time: Int64
}

class GraphView: UIView {
    let lock = NSLock()
    let maxPoints = 1500
    let maxSignal = 1800.0
    let refreshRate = 1.0 / 30
    let dataChannels: [IXNEeg] = [.EEG1, .EEG2, .EEG3, .EEG4]
    let darkColor: [IXNEeg: UIColor] = [.EEG1: .systemGreen, .EEG2: .red, .EEG3: .systemBlue, .EEG4: .white]
    let lightColor: [IXNEeg: UIColor] = [.EEG1: .systemGreen, .EEG2: .purple, .EEG3: .systemBlue, .EEG4: .darkGray]
    var dataPoints = [IXNEeg: [DataPoint]]()
    var updateTimer: Timer?
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        for ch in dataChannels {
            dataPoints[ch] = [DataPoint]()
        }
    }
    
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        for ch in dataChannels {
            drawChannel(rect, channel: ch)
        }
        let context = UIGraphicsGetCurrentContext()!
        context.setStrokeColor(UIColor.darkGray.cgColor)
        context.setLineWidth(2.0)
        context.addRect(rect)
        context.strokePath()
    }
    
    func drawChannel(_ rect: CGRect, channel: IXNEeg) {
        lock.lock()
        defer {
            lock.unlock()
        }
        let points = dataPoints[channel]!
        let maxPoints = points.count;
        let numPoints = min(Int(rect.width), maxPoints)
        var displayPoints = [Int]()
        let ySize = rect.height / CGFloat(dataChannels.count)
        let yScale = rect.height / (CGFloat(dataChannels.count) * maxSignal)
        
        if numPoints == 0 {
            return
        }
        
        let index = maxPoints - numPoints
        let offset = ySize * CGFloat(channel.rawValue) + ySize / 16;
        
        for n in 0...numPoints {
            let i = index + n
            if i >= maxPoints {
                break
            }
            displayPoints.append(Int((points[i].value * yScale) + offset))
        }
        
        let context = UIGraphicsGetCurrentContext()!
        context.setStrokeColor(graphColor(channel: channel).cgColor)
        context.setLineWidth(1.0)
        
        // Move to the first point
        context.move(to: CGPoint(x: 0, y: displayPoints[0]))
        
        // Draw a line to each subsequent point
        for i in 1..<displayPoints.count {
            context.addLine(to: CGPoint(x: i, y: displayPoints[i]))
        }
        
        context.strokePath()
    }
    
    func addPoint(packet: IXNMuseDataPacket) {
        lock.lock()
        defer {
            lock.unlock()
        }
        for ch in dataChannels {
            if dataPoints[ch] != nil {
                var value = packet.getEegChannelValue(ch)
                value = value.isNaN ? 0 : value
                dataPoints[ch]!.append(DataPoint(value: value, time: packet.timestamp()))
                if dataPoints[ch]!.count > maxPoints {
                    dataPoints[ch]!.remove(at: 0)
                }
            }
        }
    }
    
    func start() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: self.refreshRate, repeats: true) { [weak self] timer in
            self?.setNeedsDisplay(self?.bounds ?? CGRect.zero)
        }
    }
    
    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    func graphColor(channel: IXNEeg) -> UIColor {
        if self.traitCollection.userInterfaceStyle == .dark {
            return darkColor[channel]!
        }
        return lightColor[channel]!
    }
}
