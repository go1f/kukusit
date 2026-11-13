import Foundation
import CoreGraphics
import PostureCore

struct PetChecks {
    func placement() {
        for area in [CGRect(x:0,y:0,width:1440,height:850), CGRect(x:-1920,y:50,width:1920,height:1030)] {
            for anchor in [CGPoint(x:area.minX,y:area.minY),CGPoint(x:area.maxX-104,y:area.maxY-174),CGPoint(x:area.midX,y:area.midY)] {
                let cat = CGRect(origin:anchor,size:CGSize(width:104,height:174))
                let sizes = Array(repeating:CGSize(width:110,height:76),count:4)
                for seed in 0..<24 {
                    let frames = PetPlacement.bubbles(around:cat,sizes:sizes,in:area,seed:seed)
                    expectTrue(frames == PetPlacement.bubbles(around:cat,sizes:sizes,in:area,seed:seed))
                    expectTrue(frames.count == 4)
                    for frame in frames {
                        expectTrue(area.contains(frame))
                        expectTrue(frame.intersection(cat).isNull || frame.intersection(cat).width*frame.intersection(cat).height < 1)
                    }
                    for i in frames.indices { for j in frames.indices where i < j {
                        expectTrue(!frames[i].intersects(frames[j]))
                    } }
                }
            }
        }
        let box = CGRect(x:0,y:0,width:1200,height:800)
        let cat = CGRect(x:400,y:300,width:104,height:174)
        let sizes = Array(repeating:CGSize(width:110,height:76),count:3)
        let first = PetPlacement.bubbles(around:cat,sizes:sizes,in:box,seed:4)
        let next = PetPlacement.bubbles(around:cat,sizes:Array(sizes.dropFirst()),in:box,seed:4,preferred:Array(first.dropFirst()).map { Optional($0) })
        expectTrue(next == Array(first.dropFirst()))
        let area = CGRect(x:0,y:0,width:800,height:600)
        expectTrue(area.contains(PetPlacement.clamp(CGRect(x:-200,y:800,width:104,height:174),to:area)))
    }
}
