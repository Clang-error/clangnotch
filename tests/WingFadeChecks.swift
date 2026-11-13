import Foundation

@main
struct WingFadeChecks {
    static func main() {
        let notch: CGFloat = 185, width: CGFloat = 400   // wings of 107.5 a side
        func at(_ stops: [(location: CGFloat, opacity: Double)], _ x: CGFloat) -> Double {
            let u = x / width
            guard let i = stops.firstIndex(where: { $0.location >= u }) else { return stops.last!.opacity }
            guard i > 0, stops[i].location > stops[i - 1].location else { return stops[i].opacity }
            let t = Double((u - stops[i - 1].location) / (stops[i].location - stops[i - 1].location))
            return stops[i - 1].opacity + (stops[i].opacity - stops[i - 1].opacity) * t
        }

        let solid = WingFade(notchWidth: notch).stops(width: width)
        precondition(solid.allSatisfy { $0.opacity == 1 }, "Nothing fades with the cursor off the wings")

        let right = WingFade(notchWidth: notch, right: 1).stops(width: width)
        let centre = width / 2, edge = centre + notch / 2
        precondition(zip(right, right.dropFirst()).allSatisfy { $0.location <= $1.location }, "Stops in order")
        precondition(at(right, centre) == 1 && at(right, edge) == 1, "The notch itself never fades")
        precondition(at(right, centre - notch / 2 - 20) == 1, "The other wing stays solid")
        precondition(abs(at(right, edge + WingFade.ramp) - WingFade.floor) < 1e-9, "Faded by the end of the ramp")
        precondition(abs(at(right, width) - WingFade.floor) < 1e-9, "And stays faded to the wing's end")
        let middle = at(right, edge + WingFade.ramp / 2)
        precondition(middle > WingFade.floor && middle < 1, "In between halfway out: \(middle)")

        let left = WingFade(notchWidth: notch, left: 1).stops(width: width)
        precondition(abs(at(left, 0) - WingFade.floor) < 1e-9 && at(left, width) == 1, "Mirrored on the left")

        // Halfway through stepping aside, halfway faded.
        let half = WingFade(notchWidth: notch, right: 0.5).stops(width: width)
        precondition(abs(at(half, width) - (1 - 0.5 * (1 - WingFade.floor))) < 1e-9)

        // Wings narrower than the ramp keep every stop on the span, in order.
        let narrow = WingFade(notchWidth: notch, left: 1, right: 1).stops(width: notch + 20)
        precondition(narrow.allSatisfy { (0...1).contains($0.location) })
        precondition(zip(narrow, narrow.dropFirst()).allSatisfy { $0.location <= $1.location })
        print("PASS: wing fade stops: notch solid, ramp to the floor on the hovered side only, mirrored, partial, narrow wings")
    }
}
