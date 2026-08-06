import GoogleMobileAds

enum AdsSpike {
    static let ready = GADMobileAds.sharedInstance() != nil
}
