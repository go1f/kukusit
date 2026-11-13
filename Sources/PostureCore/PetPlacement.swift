import Foundation
import CoreGraphics

public enum PetPlacement {
    public static func clamp(_ rect: CGRect, to area: CGRect) -> CGRect {
        CGRect(x: min(max(rect.minX,area.minX), max(area.minX,area.maxX-rect.width)),
            y: min(max(rect.minY,area.minY),max(area.minY,area.maxY-rect.height)), width: rect.width,height:rect.height)
    }
    /// Stable seeded choices distribute speech on all sides. Greedy collision scoring
    /// keeps bubbles near the cat while preferring readable, non-overlapping positions.
    public static func bubbles(around cat: CGRect, sizes: [CGSize], in area: CGRect, seed: Int, preferred: [CGRect?] = []) -> [CGRect] {
        var result: [CGRect] = []
        let reserved = preferred.compactMap { $0 }.filter { area.contains($0) }
        for (index,size) in sizes.enumerated() {
            if index < preferred.count, let fixed = preferred[index], area.contains(fixed) { result.append(fixed); continue }
            var candidates = (0..<24).map { offset -> CGRect in
                let step = (offset + seed + index*5)%24
                let angle = Double(step)*Double.pi/12
                let dx = cos(angle)*(cat.width/2+size.width/2+12)
                let dy = sin(angle)*(cat.height/2+size.height/2+12)
                return clamp(CGRect(x:cat.midX+dx-size.width/2,y:cat.midY+dy-size.height/2,width:size.width,height:size.height),to:area)
            }
            for slot in -4...4 {
                for x in [cat.maxX+10,cat.minX-size.width-10] {
                    candidates.append(clamp(CGRect(x:x,y:cat.midY-size.height/2+Double(slot)*(size.height+8),width:size.width,height:size.height),to:area))
                }
                for y in [cat.maxY+10,cat.minY-size.height-10] {
                    candidates.append(clamp(CGRect(x:cat.midX-size.width/2+Double(slot)*(size.width+8),y:y,width:size.width,height:size.height),to:area))
                }
            }
            func overlap(_ a: CGRect,_ b: CGRect) -> Double { let i = a.intersection(b); return i.isNull ? 0 : i.width*i.height }
            func cost(_ frame: CGRect) -> Double {
                overlap(frame,cat)*10000 + result.reduce(0) { $0+overlap(frame.insetBy(dx:-4,dy:-4),$1)*10000 } + reserved.reduce(0) { $0+overlap(frame.insetBy(dx:-4,dy:-4),$1)*10000 } + hypot(frame.midX-cat.midX,frame.midY-cat.midY) + 22*sin(frame.midX*0.13+frame.midY*0.07+Double(seed))
            }
            if let best = candidates.min(by: { cost($0) < cost($1) }) { result.append(best) }
        }
        return result
    }
}
