import Foundation

@main
struct TutorialLaunchChecks {
    static func main() {
        func d(_ last: String?, settings: Bool = true, seen: Bool = false, tutorial: Bool = false,
               whatsNew: Bool = false) -> TutorialLaunch {
            TutorialLaunch.decide(currentVersion: "1.6.0", lastVersion: last, hadSettings: settings, tutorialSeen: seen,
                                  forceTutorial: tutorial, forceWhatsNew: whatsNew)
        }
        precondition(d(nil, settings: false) == .tutorial(linksWhatsNew: false), "A first install gets the tutorial, with no notes to link")
        precondition(d("1.5.0") == .tutorial(linksWhatsNew: true), "The first update with it: the tutorial instead of 새로운 점, linking to it")
        precondition(d(nil, settings: true) == .tutorial(linksWhatsNew: true), "An update from 1.4.0 or older (no version recorded) counts as an update")
        precondition(d("1.4.1") == .tutorial(linksWhatsNew: true), "Skipping versions still gets it once")
        precondition(d("1.5.0", seen: true) == .whatsNew, "Once seen, later updates get 새로운 점 as before")
        precondition(d("1.6.0", seen: true) == .nothing && d("1.6.0") == .nothing, "The same version again: nothing")
        precondition(d("1.6.0", seen: true, tutorial: true) == .tutorial(linksWhatsNew: false), "--tutorial shows it any time")
        precondition(d("1.6.0", seen: true, whatsNew: true) == .whatsNew, "--whats-new still shows 새로운 점")
        print("TutorialLaunchChecks: all passed")
    }
}
