import Testing
import CSMC
import CoolMacHardware

@Test func floatRoundTrip() throws {
    var value = CMValue()
    value.type = cm_fourcc("flt ")
    value.size = 4
    var encoded = CMValue()
    #expect(cm_encode_number(&value, 3499, &encoded) == 0)
    var number = 0.0
    #expect(cm_decode_number(&encoded, &number) == 0)
    #expect(number == 3499)
}

@Test func fixedPointRoundTrip() {
    var value = CMValue()
    value.type = cm_fourcc("fpe2")
    value.size = 2
    var encoded = CMValue()
    #expect(cm_encode_number(&value, 1200.25, &encoded) == 0)
    var number = 0.0
    #expect(cm_decode_number(&encoded, &number) == 0)
    #expect(number == 1200.25)
    #expect(cm_encode_number(&value, 17000, &encoded) != 0)
}

@Test func rejectsUnknownAndNonfinite() {
    var value = CMValue()
    value.type = cm_fourcc("evil")
    value.size = 4
    var encoded = CMValue()
    var number = 0.0
    #expect(cm_decode_number(&value, &number) != 0)
    #expect(cm_encode_number(&value, 1000, &encoded) != 0)
    value.type = cm_fourcc("flt ")
    #expect(cm_encode_number(&value, .nan, &encoded) != 0)
    #expect(cm_encode_number(&value, .infinity, &encoded) != 0)
}

@Test func zeroFanIsValidAndModeIsExact() {
    var value = CMValue()
    value.type = cm_fourcc("ui8 ")
    value.size = 1
    var encoded = CMValue()
    #expect(cm_encode_number(&value, 0, &encoded) == 0)
    var number = -1.0
    #expect(cm_decode_number(&encoded, &number) == 0)
    #expect(number == 0)
    #expect(cm_encode_number(&value, 0.5, &encoded) != 0)
}

@Test func clockIsMonotonic() {
    let first = ContinuousClock.now
    let second = ContinuousClock.now
    #expect(second >= first)
}
