# Isolate each test process tree without enumerating or terminating unrelated processes.
function Initialize-TestProcessJobType {

    if ('Seamless.TestProcessJob' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Seamless
{
    // Own one test process tree, including children started by that test.
    public sealed class TestProcessJob : IDisposable
    {
        private IntPtr handle;
        private const uint KillOnJobClose = 0x2000;
        private const int ExtendedLimitInformation = 9;
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimits
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperations, WriteOperations, OtherOperations;
            public ulong ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimits
        {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        // Configure Windows to terminate all members when this job handle closes.
        public TestProcessJob()
        {
            handle = CreateJobObject(IntPtr.Zero, null);

            if (handle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            var limits = new ExtendedLimits();
            limits.Basic.LimitFlags = KillOnJobClose;

            if (!SetInformationJobObject(handle, ExtendedLimitInformation, ref limits, (uint)Marshal.SizeOf(limits)))
            {
                int error = Marshal.GetLastWin32Error();
                Dispose();
                throw new Win32Exception(error);
            }
        }

        // Attach the waiting test host before its startup gate opens.
        public void Attach(IntPtr processHandle)
        {

            if (!AssignProcessToJobObject(handle, processHandle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        // Stop only processes assigned to this test's job after its deadline.
        public void Terminate()
        {
            const uint timeoutExitCode = 1;

            if (!TerminateJobObject(handle, timeoutExitCode))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        // Release the job once; closing it also reaps any surviving descendants.
        public void Dispose()
        {

            if (handle == IntPtr.Zero)
            {
                return;
            }

            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }
}
'@
}
