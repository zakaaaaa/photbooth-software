// ===========================================================================
// Edsdk.cs — binding P/Invoke minimal ke Canon EDSDK (Windows, x86).
//
// Signature & layout struct di sini TIDAK ditebak: semuanya diverifikasi
// terhadap EDSDK.dll 13.18.40 (x86) yang terpasang bersama digiCamControl.
//   - Calling convention: seluruh export berakhir `ret <n>` (mis.
//     EdsDownloadEvfImage → `5E 5D C2 08 00`), jadi murni __stdcall.
//     Varian "Cdecl" yang ada di binding lama hanya relevan untuk EDSDK
//     generasi sebelumnya; JANGAN dipakai untuk 13.x.
//   - EdsDirectoryItemInfo.Size = UInt64 (bukan UInt32 seperti EDSDK <3.8);
//     sizeof struct = 288 byte di x86.
//   - EdsCapacity memakai Pack = 2 (12 byte), berbeda dari struct lain.
//
// Hanya subset yang dipakai photobooth yang dideklarasikan.
// ===========================================================================

using System;
using System.Runtime.InteropServices;

namespace EdsdkBridge
{
    internal static class Eds
    {
        private const string DLL = "EDSDK.dll";
        private const CallingConvention CC = CallingConvention.StdCall;

        // ---------------- Error codes ----------------
        public const uint EDS_ERR_OK = 0x00000000;
        public const uint EDS_ERR_DEVICE_BUSY = 0x00000081;
        public const uint EDS_ERR_OBJECT_NOTREADY = 0x0000A102;
        public const uint EDS_ERR_DEVICE_INVALID = 0x00000080;
        public const uint EDS_ERR_COMM_DISCONNECTED = 0x000000C5;
        public const uint EDS_ERR_INVALID_HANDLE = 0x00000060;

        // ---------------- Property IDs ----------------
        public const uint PropID_ProductName = 0x00000002;
        public const uint PropID_BodyIDEx = 0x00000015;
        public const uint PropID_SaveTo = 0x0000000B;
        public const uint PropID_ImageQuality = 0x00000100;
        public const uint PropID_AEMode = 0x00000400;
        public const uint PropID_ISOSpeed = 0x00000402;
        public const uint PropID_Av = 0x00000405;
        public const uint PropID_Tv = 0x00000406;
        public const uint PropID_AvailableShots = 0x0000040A;
        public const uint PropID_Evf_OutputDevice = 0x00000500;
        public const uint PropID_Evf_Mode = 0x00000501;
        public const uint PropID_Evf_AFMode = 0x0000050E;
        public const uint PropID_Evf_Zoom = 0x00000507;
        public const uint PropID_Evf_Histogram = 0x0000050A;
        public const uint PropID_Evf_DepthOfFieldPreview = 0x00000504;

        // ---------------- Evf output device (bitmask) ----------------
        public const uint EvfOutputDevice_TFT = 0x00000001;
        public const uint EvfOutputDevice_PC = 0x00000002;
        public const uint EvfOutputDevice_MOBILE = 0x00000004;
        public const uint EvfOutputDevice_PC_Small = 0x00000008;

        // ---------------- Image quality ----------------
        // kEdsImageQuality adalah 32 bit yang dibaca per byte:
        //   [size1][quality1][size2][quality2]
        //   size    : 0x00=Large, 0x01=Middle, 0x02=Small, 0x07=S1,
        //             0x08=S2, 0x09=S3, 0xFF=slot kosong
        //   quality : 0x10=JPEG Fine, 0x13=JPEG Normal, 0x64=RAW,
        //             0x0F=slot kosong
        // Slot kedua terisi berarti RAW+JPEG (dua file per jepret).
        public const uint ImageQuality_LargeFineJpeg = 0x0010FF0F;
        public const uint ImageQuality_LargeNormalJpeg = 0x0013FF0F;

        // ---------------- SaveTo ----------------
        public const uint SaveTo_Camera = 1;
        public const uint SaveTo_Host = 2;
        public const uint SaveTo_Both = 3;

        // ---------------- Camera commands ----------------
        public const uint CameraCommand_TakePicture = 0x00000000;
        public const uint CameraCommand_ExtendShutDownTimer = 0x00000001;
        public const uint CameraCommand_PressShutterButton = 0x00000004;
        public const uint CameraCommand_DoEvfAf = 0x00000102;
        public const uint CameraCommand_DriveLensEvf = 0x00000103;

        // ---------------- Shutter button params ----------------
        public const int ShutterButton_OFF = 0x00000000;
        public const int ShutterButton_Halfway = 0x00000001;
        public const int ShutterButton_Completely = 0x00000003;
        public const int ShutterButton_Halfway_NonAF = 0x00010001;
        public const int ShutterButton_Completely_NonAF = 0x00010003;

        // ---------------- Events ----------------
        public const uint ObjectEvent_All = 0x00000200;
        public const uint ObjectEvent_DirItemCreated = 0x00000204;
        public const uint ObjectEvent_DirItemRequestTransfer = 0x00000208;

        public const uint StateEvent_All = 0x00000300;
        public const uint StateEvent_Shutdown = 0x00000301;
        public const uint StateEvent_WillSoonShutDown = 0x00000303;
        public const uint StateEvent_CaptureError = 0x00000305;
        public const uint StateEvent_InternalError = 0x00000306;
        public const uint StateEvent_AfResult = 0x00000309;

        public const uint PropertyEvent_All = 0x00000100;

        // ---------------- Structs ----------------
        [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Ansi)]
        public struct EdsDeviceInfo
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string szPortName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string szDeviceDescription;
            public uint DeviceSubType;
            public uint reserved;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Ansi)]
        public struct EdsDirectoryItemInfo
        {
            public ulong Size;
            public int isFolder;
            public uint GroupID;
            public uint Option;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string szFileName;
            public uint format;
            public uint dateTime;
        }

        // PropDesc = daftar nilai yang DIDUKUNG body untuk sebuah properti.
        // Dipakai agar pemilihan kualitas gambar tidak menebak konstanta,
        // melainkan memilih dari yang benar-benar ditawarkan kamera.
        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        public struct EdsPropertyDesc
        {
            public int Form;
            public uint Access;
            public int NumElements;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
            public int[] PropDesc;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 2)]
        public struct EdsCapacity
        {
            public int NumberOfFreeClusters;
            public int BytesPerSector;
            public int Reset;
        }

        // ---------------- Callback delegates (stdcall) ----------------
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        public delegate uint EdsObjectEventHandler(uint inEvent, IntPtr inRef, IntPtr inContext);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        public delegate uint EdsStateEventHandler(uint inEvent, uint inParameter, IntPtr inContext);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        public delegate uint EdsPropertyEventHandler(uint inEvent, uint inPropertyID, uint inParam, IntPtr inContext);

        // ---------------- SDK lifecycle ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsInitializeSDK();

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsTerminateSDK();

        // ---------------- Object tree ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetCameraList(out IntPtr outCameraListRef);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetChildCount(IntPtr inRef, out int outCount);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetChildAtIndex(IntPtr inRef, int inIndex, out IntPtr outRef);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetDeviceInfo(IntPtr inCameraRef, out EdsDeviceInfo outDeviceInfo);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsRelease(IntPtr inRef);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsRetain(IntPtr inRef);

        // ---------------- Session ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsOpenSession(IntPtr inCameraRef);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsCloseSession(IntPtr inCameraRef);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsSetCapacity(IntPtr inCameraRef, EdsCapacity inCapacity);

        // ---------------- Properties ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetPropertyData(IntPtr inRef, uint inPropertyID, int inParam,
                                                     int inPropertySize, IntPtr outPropertyData);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsSetPropertyData(IntPtr inRef, uint inPropertyID, int inParam,
                                                     int inPropertySize, IntPtr inPropertyData);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetPropertySize(IntPtr inRef, uint inPropertyID, int inParam,
                                                     out int outDataType, out int outSize);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetPropertyDesc(IntPtr inRef, uint inPropertyID,
                                                     out EdsPropertyDesc outPropertyDesc);

        // ---------------- Commands ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsSendCommand(IntPtr inCameraRef, uint inCommand, int inParam);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsSendStatusCommand(IntPtr inCameraRef, uint inCameraState, int inParam);

        // ---------------- Streams ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsCreateMemoryStream(ulong inBufferSize, out IntPtr outStream);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetPointer(IntPtr inStreamRef, out IntPtr outPointer);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetLength(IntPtr inStreamRef, out ulong outLength);

        // ---------------- Live view (EVF) ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsCreateEvfImageRef(IntPtr inStreamRef, out IntPtr outEvfImageRef);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsDownloadEvfImage(IntPtr inCameraRef, IntPtr outEvfImageRef);

        // ---------------- Download foto ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsGetDirectoryItemInfo(IntPtr inDirItemRef, out EdsDirectoryItemInfo outDirItemInfo);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsDownload(IntPtr inDirItemRef, ulong inReadSize, IntPtr outStream);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsDownloadComplete(IntPtr inDirItemRef);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsDownloadCancel(IntPtr inDirItemRef);

        // ---------------- Event handler registration ----------------
        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsSetObjectEventHandler(IntPtr inCameraRef, uint inEvent,
                                                           EdsObjectEventHandler inHandler, IntPtr inContext);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsSetCameraStateEventHandler(IntPtr inCameraRef, uint inEvent,
                                                                EdsStateEventHandler inHandler, IntPtr inContext);

        [DllImport(DLL, CallingConvention = CC)]
        public static extern uint EdsSetPropertyEventHandler(IntPtr inCameraRef, uint inEvent,
                                                             EdsPropertyEventHandler inHandler, IntPtr inContext);
    }
}
