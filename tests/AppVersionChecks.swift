import Foundation

@main
struct AppVersionChecks {
    static func main() {
        func v(_ s: String) -> AppVersion { AppVersion(s) }
        precondition(v("1.4.1-beta.3") > v("1.4.0"), "A beta is newer than the release before it")
        precondition(v("1.4.1") > v("1.4.1-beta.3"), "The release is newer than its betas")
        precondition(v("1.4.1-beta.3") > v("1.4.1-beta.2"), "Betas count up")
        precondition(v("1.4.1-beta.10") > v("1.4.1-beta.9"), "By number, not by text")
        precondition(v("1.10") > v("1.9") && v("1.1") > v("1.0.9"), "Each part by number")
        precondition(v("1.4") == v("1.4.0") && v("v1.4.0") == v("1.4.0"), "Missing parts are 0; the tag's v is dropped")
        precondition(!(v("1.4.0") > v("1.4.1-beta.3")), "The release before isn't newer than a beta")
        precondition(v("1.4.1-beta.3").isBeta && !v("1.4.1").isBeta, "Beta or not")
        precondition(v("1.5.0-beta.1") > v("1.4.9"), "A beta of a later number beats any earlier release")
        print("AppVersionChecks: all passed")
    }
}
