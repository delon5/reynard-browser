import Foundation

@main
enum FairPlaySPCVersionProbeTests {
    static func main() {
        precondition(FairPlaySPCVersionProbe.selectedVersion(from: nil) == 1)
        precondition(FairPlaySPCVersionProbe.selectedVersion(from: "1") == 1)
        precondition(FairPlaySPCVersionProbe.selectedVersion(from: "2") == 2)
        precondition(FairPlaySPCVersionProbe.selectedVersion(from: "3") == 3)

        for invalid in ["", "0", "4", " 2", "+2", "two"] {
            precondition(
                FairPlaySPCVersionProbe.selectedVersion(from: invalid) == 1,
                "Invalid probe value must preserve the version-1 fallback."
            )
        }

        precondition(
            FairPlaySPCVersionProbe.encodedVersion(in: Data()) == nil
        )
        precondition(
            FairPlaySPCVersionProbe.encodedVersion(
                in: Data([0x00, 0x00, 0x01])
            ) == nil
        )

        for version in UInt8(1)...UInt8(3) {
            let spc = Data([0x00, 0x00, 0x00, version, 0xaa, 0xbb])
            precondition(
                FairPlaySPCVersionProbe.encodedVersion(in: spc) ==
                    UInt32(version)
            )
        }

        precondition(
            FairPlaySPCVersionProbe.encodedVersion(
                in: Data([0x00, 0x00, 0x00, 0x00])
            ) == nil
        )
        precondition(
            FairPlaySPCVersionProbe.encodedVersion(
                in: Data([0x00, 0x00, 0x00, 0x04])
            ) == nil
        )

        // configuredVersion is seeded from the environment and then
        // written by the preference. Both paths go through the same
        // validation, so an out-of-range write cannot get past it.
        let seeded = FairPlaySPCVersionProbe.configuredVersion
        precondition((1...3).contains(seeded))
        for raw in ["3", "bogus", "0"] {
            FairPlaySPCVersionProbe.configuredVersion =
                FairPlaySPCVersionProbe.selectedVersion(from: raw)
            precondition((1...3).contains(
                FairPlaySPCVersionProbe.configuredVersion))
        }
        FairPlaySPCVersionProbe.configuredVersion = seeded

        // An out-of-range encoded version is reported, not hidden.
        precondition(
            FairPlaySPCVersionProbe.describeEncodedVersion(
                in: Data([0x00, 0x00, 0x00, 0x05])
            ) == "unexpected 5"
        )
        precondition(
            FairPlaySPCVersionProbe.describeEncodedVersion(
                in: Data([0x00, 0x00, 0x00, 0x02])
            ) == "2"
        )
        precondition(
            FairPlaySPCVersionProbe.describeEncodedVersion(
                in: Data([0x00, 0x00])
            ) == "unavailable"
        )

        print("FairPlaySPCVersionProbeTests passed")
    }
}
