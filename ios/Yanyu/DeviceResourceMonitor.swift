#if DEBUG
  import Darwin
  import Foundation

  struct DeviceResourceMeasurement: Equatable {
    let peakSampledMemoryFootprintBytes: UInt64?
    let thermalStates: [String]
    let sampleIntervalMs: UInt64
  }

  @MainActor
  final class DeviceResourceMonitor {
    private static let sampleIntervalMs: UInt64 = 100
    private var sampleTask: Task<Void, Never>?
    private var peakSampledMemoryFootprintBytes: UInt64?
    private var thermalStates: [String] = []
    private var finalMeasurement: DeviceResourceMeasurement?

    func start() {
      guard sampleTask == nil, finalMeasurement == nil else {
        return
      }
      recordSample()
      sampleTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(Self.sampleIntervalMs))
          guard !Task.isCancelled else {
            break
          }
          self?.recordSample()
        }
      }
    }

    @discardableResult
    func stop() -> DeviceResourceMeasurement {
      if let finalMeasurement {
        return finalMeasurement
      }
      sampleTask?.cancel()
      sampleTask = nil
      recordSample()
      let measurement = DeviceResourceMeasurement(
        peakSampledMemoryFootprintBytes: peakSampledMemoryFootprintBytes,
        thermalStates: thermalStates,
        sampleIntervalMs: Self.sampleIntervalMs
      )
      finalMeasurement = measurement
      return measurement
    }

    private func recordSample() {
      if let currentMemory = currentMemoryFootprintBytes() {
        peakSampledMemoryFootprintBytes = max(
          peakSampledMemoryFootprintBytes ?? currentMemory,
          currentMemory
        )
      }

      let thermalState = thermalStateName(ProcessInfo.processInfo.thermalState)
      if thermalStates.last != thermalState {
        thermalStates.append(thermalState)
      }
    }

    private func currentMemoryFootprintBytes() -> UInt64? {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
      )
      let status = withUnsafeMutablePointer(to: &info) { infoPointer in
        infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { infoPointer in
          task_info(
            mach_task_self_,
            task_flavor_t(TASK_VM_INFO),
            infoPointer,
            &count
          )
        }
      }
      guard status == KERN_SUCCESS else {
        return nil
      }
      return UInt64(info.phys_footprint)
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
      switch state {
      case .nominal:
        "nominal"
      case .fair:
        "fair"
      case .serious:
        "serious"
      case .critical:
        "critical"
      @unknown default:
        "unknown"
      }
    }
  }
#endif
