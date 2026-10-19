import Testing
@testable import Sidetable

@Test func connectionAvailabilityRequiresBothWakeAndNetwork() {
    var availability = ConnectionAvailability()
    #expect(availability.canConnect)
    availability.awake = false
    #expect(!availability.canConnect)
    availability.networkAvailable = false
    availability.awake = true
    #expect(!availability.canConnect)
    availability.networkAvailable = true
    #expect(availability.canConnect)
    availability.awake = false
    availability.networkAvailable = true
    #expect(!availability.canConnect)
}
