using System.Runtime.InteropServices;

namespace AVDTune.Bench;

// Own Media Foundation interop (no third-party library). Interface method order follows mftransform.h / mfobjects.h / strmif.h.
// Methods the program never calls are declared with a plain signature: only their position in the vtable matters.

[ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFAttributes
{
    void GetItem(); void GetItemType(); void CompareItem(); void Compare();
    void GetUINT32(ref Guid key, out uint value);
    void GetUINT64(ref Guid key, out ulong value);
    void GetDouble(); void GetGUID(); void GetStringLength(); void GetString(); void GetAllocatedString(); void GetBlobSize(); void GetBlob(); void GetAllocatedBlob(); void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
    void SetUINT32(ref Guid key, uint value);
    void SetUINT64(ref Guid key, ulong value);
    void SetDouble();
    void SetGUID(ref Guid key, ref Guid value);
    void SetString(); void SetBlob(); void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount(); void GetItemByIndex(); void CopyAllItems();
}

[ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFMediaType : IMFAttributes
{
    // vtable order matters: the IMFAttributes methods come first (inherited), these follow
    void GetMajorType(); void IsCompressedFormat(); void IsEqual(); void GetRepresentation(); void FreeRepresentation();
}

[ComImport, Guid("045fa593-8799-42b8-bc8d-8968c6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFMediaBuffer
{
    void Lock(out IntPtr buffer, out uint maxLength, out uint currentLength);
    void Unlock();
    void GetCurrentLength(out uint length);
    void SetCurrentLength(uint length);
    void GetMaxLength(out uint length);
}

[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFSample
{
    // IMFAttributes part, declared flat (30 methods) so the vtable positions are explicit
    void a01(); void a02(); void a03(); void a04(); void a05(); void a06(); void a07(); void a08(); void a09(); void a10();
    void a11(); void a12(); void a13(); void a14(); void a15(); void a16(); void a17(); void a18(); void a19(); void a20();
    void a21(); void a22(); void a23(); void a24(); void a25(); void a26(); void a27(); void a28(); void a29(); void a30();
    void GetSampleFlags(); void SetSampleFlags();
    void GetSampleTime(out long time);
    void SetSampleTime(long time);
    void GetSampleDuration(out long duration);
    void SetSampleDuration(long duration);
    void GetBufferCount(out uint count);
    void GetBufferByIndex(uint index, out IMFMediaBuffer buffer);
    void ConvertToContiguousBuffer(out IMFMediaBuffer buffer);
    void AddBuffer(IMFMediaBuffer buffer);
    void RemoveBufferByIndex(uint index);
    void RemoveAllBuffers();
    void GetTotalLength(out uint length);
    void CopyToBuffer(IMFMediaBuffer buffer);
}

[StructLayout(LayoutKind.Sequential)]
internal struct MFT_OUTPUT_STREAM_INFO { public uint dwFlags; public uint cbSize; public uint cbAlignment; }

[StructLayout(LayoutKind.Sequential)]
internal struct MFT_INPUT_STREAM_INFO { public long hnsMaxLatency; public uint dwFlags; public uint cbSize; public uint cbMaxLookahead; public uint cbAlignment; }

[StructLayout(LayoutKind.Sequential)]
internal struct MFT_OUTPUT_DATA_BUFFER { public uint dwStreamID; public IntPtr pSample; public uint dwStatus; public IntPtr pEvents; }

[ComImport, Guid("bf94c121-5b05-4e6f-8000-ba598961414d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFTransform
{
    void GetStreamLimits(out uint inMin, out uint inMax, out uint outMin, out uint outMax);
    void GetStreamCount(out uint inputs, out uint outputs);
    void GetStreamIDs(uint inCount, IntPtr inIds, uint outCount, IntPtr outIds);
    void GetInputStreamInfo(uint streamId, out MFT_INPUT_STREAM_INFO info);
    void GetOutputStreamInfo(uint streamId, out MFT_OUTPUT_STREAM_INFO info);
    void GetAttributes(out IMFAttributes attributes);
    void GetInputStreamAttributes(uint streamId, out IMFAttributes attributes);
    void GetOutputStreamAttributes(uint streamId, out IMFAttributes attributes);
    void DeleteInputStream(uint streamId);
    void AddInputStreams(uint count, IntPtr ids);
    [PreserveSig] int GetInputAvailableType(uint streamId, uint index, out IMFMediaType type);
    [PreserveSig] int GetOutputAvailableType(uint streamId, uint index, out IMFMediaType type);
    void SetInputType(uint streamId, IMFMediaType type, uint flags);
    void SetOutputType(uint streamId, IMFMediaType type, uint flags);
    void GetInputCurrentType(uint streamId, out IMFMediaType type);
    void GetOutputCurrentType(uint streamId, out IMFMediaType type);
    void GetInputStatus(uint streamId, out uint flags);
    void GetOutputStatus(out uint flags);
    void SetOutputBounds(long lower, long upper);
    void ProcessEvent(uint streamId, IntPtr evt);
    void ProcessMessage(int message, UIntPtr param);
    [PreserveSig] int ProcessInput(uint streamId, IMFSample sample, uint flags);
    [PreserveSig] int ProcessOutput(uint flags, uint count, ref MFT_OUTPUT_DATA_BUFFER buffer, out uint status);
}

[StructLayout(LayoutKind.Explicit, Size = 24)]
internal struct PropVariant
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public uint ulVal;
    public static PropVariant UInt32(uint v) => new() { vt = 19, ulVal = v };   // VT_UI4
    public static PropVariant Bool(bool v) => new() { vt = 11, ulVal = v ? 0xFFFFu : 0u };   // VT_BOOL: VARIANT_TRUE = -1 (16 bit)
}

[ComImport, Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ICodecAPI
{
    [PreserveSig] int IsSupported(ref Guid api);
    [PreserveSig] int IsModifiable(ref Guid api);
    void GetParameterRange(); void GetParameterValues(); void GetDefaultValue();
    void GetValue();
    [PreserveSig] int SetValue(ref Guid api, ref PropVariant value);
}

internal static class MF
{
    public const uint Version = 0x00020070;
    [DllImport("mfplat.dll")] public static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll")] public static extern int MFShutdown();
    [DllImport("mfplat.dll")] public static extern int MFCreateMediaType(out IMFMediaType type);
    [DllImport("mfplat.dll")] public static extern int MFCreateSample(out IMFSample sample);
    [DllImport("mfplat.dll")] public static extern int MFCreateMemoryBuffer(uint cb, out IMFMediaBuffer buffer);

    public static Guid MT_MAJOR_TYPE = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static Guid MT_SUBTYPE = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static Guid MT_FRAME_SIZE = new("1652c33d-d6b2-4012-b834-72030849a37d");
    public static Guid MT_FRAME_RATE = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static Guid MT_PIXEL_ASPECT = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    public static Guid MT_INTERLACE = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static Guid MT_AVG_BITRATE = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static Guid MT_MPEG2_PROFILE = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
    public static Guid MediaTypeVideo = new("73646976-0000-0010-8000-00aa00389b71");
    public static Guid VideoH264 = new("34363248-0000-0010-8000-00aa00389b71");
    public static Guid VideoNV12 = new("3231564e-0000-0010-8000-00aa00389b71");
    public static Guid ClsidMsH264Encoder = new("6ca50344-051a-4ded-9779-a43305165e35");
    public static Guid CodecRateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    public static Guid CodecMeanBitRate = new("f7222374-2144-4815-b550-a37f8e12ee52");
    public static Guid CodecLowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");

    public const int MessageCommandDrain = 1;
    public const int MessageBeginStreaming = 0x10000000;
    public const int MessageEndStreaming = 0x10000001;
    public const int MessageStartOfStream = 0x10000003;
    public const uint NeedMoreInput = 0xC00D6D72;
    public const uint StreamChange = 0xC00D6D61;
    public const uint OutputProvidesSamples = 0x100;

    public static ulong Pack(uint hi, uint lo) => ((ulong)hi << 32) | lo;
}

/// <summary>Software H.264 encode with the Microsoft H.264 Video Encoder MFT, created by its CLSID so no hardware encoder is picked.</summary>
internal static class H264Soft
{
    public sealed record EncodeResult(int Frames, double Seconds, long OutputBytes, string Note);

    /// <summary>Encodes all frames (NV12, width x height) as fast as possible; returns the time from the first input to the last output.</summary>
    public static EncodeResult Encode(byte[][] frames, int width, int height, int fps, int bitrate)
    {
        int hr = MF.MFStartup(MF.Version, 0);
        if (hr < 0) throw new InvalidOperationException($"MFStartup failed (0x{hr:X8}): Media Foundation is not available.");
        try
        {
            var type = Type.GetTypeFromCLSID(MF.ClsidMsH264Encoder, throwOnError: false)
                ?? throw new InvalidOperationException("The Microsoft H.264 encoder is not registered.");
            object com;
            try { com = Activator.CreateInstance(type)!; }
            catch (COMException e) { throw new InvalidOperationException($"The Microsoft H.264 encoder cannot be created (0x{e.HResult:X8})."); }
            var mft = (IMFTransform)com;
            string note = "";
            // codec properties: CBR, mean bit rate, low latency (failures are not fatal, the output type carries the bit rate too)
            if (com is ICodecAPI codec)
            {
                var low = PropVariant.Bool(true); var cbr = PropVariant.UInt32(0); var br = PropVariant.UInt32((uint)bitrate);
                int r1 = codec.SetValue(ref MF.CodecLowLatency, ref low);
                int r2 = codec.SetValue(ref MF.CodecRateControlMode, ref cbr);
                int r3 = codec.SetValue(ref MF.CodecMeanBitRate, ref br);
                if (r1 < 0 || r2 < 0 || r3 < 0) note = $"codec api: lowLatency 0x{r1:X8} cbr 0x{r2:X8} bitrate 0x{r3:X8}";
            }
            MF.MFCreateMediaType(out var outType);
            outType.SetGUID(ref MF.MT_MAJOR_TYPE, ref MF.MediaTypeVideo);
            outType.SetGUID(ref MF.MT_SUBTYPE, ref MF.VideoH264);
            outType.SetUINT32(ref MF.MT_AVG_BITRATE, (uint)bitrate);
            outType.SetUINT64(ref MF.MT_FRAME_SIZE, MF.Pack((uint)width, (uint)height));
            outType.SetUINT64(ref MF.MT_FRAME_RATE, MF.Pack((uint)fps, 1));
            outType.SetUINT64(ref MF.MT_PIXEL_ASPECT, MF.Pack(1, 1));
            outType.SetUINT32(ref MF.MT_INTERLACE, 2);          // progressive
            outType.SetUINT32(ref MF.MT_MPEG2_PROFILE, 100);    // High
            mft.SetOutputType(0, outType, 0);

            MF.MFCreateMediaType(out var inType);
            inType.SetGUID(ref MF.MT_MAJOR_TYPE, ref MF.MediaTypeVideo);
            inType.SetGUID(ref MF.MT_SUBTYPE, ref MF.VideoNV12);
            inType.SetUINT64(ref MF.MT_FRAME_SIZE, MF.Pack((uint)width, (uint)height));
            inType.SetUINT64(ref MF.MT_FRAME_RATE, MF.Pack((uint)fps, 1));
            inType.SetUINT64(ref MF.MT_PIXEL_ASPECT, MF.Pack(1, 1));
            inType.SetUINT32(ref MF.MT_INTERLACE, 2);
            mft.SetInputType(0, inType, 0);

            mft.GetOutputStreamInfo(0, out var outInfo);
            bool mftAllocates = (outInfo.dwFlags & (MF.OutputProvidesSamples)) != 0;
            uint outSize = Math.Max(outInfo.cbSize, (uint)(width * height));
            mft.ProcessMessage(MF.MessageBeginStreaming, UIntPtr.Zero);
            mft.ProcessMessage(MF.MessageStartOfStream, UIntPtr.Zero);

            long duration = 10_000_000L / fps;
            long outBytes = 0;
            int frameBytes = width * height * 3 / 2;

            // reusable output sample when the MFT does not allocate
            IMFSample? ownOut = null; IMFMediaBuffer? ownBuf = null;
            if (!mftAllocates) { MF.MFCreateSample(out ownOut); MF.MFCreateMemoryBuffer(outSize, out ownBuf); ownOut.AddBuffer(ownBuf); }

            long PullOutputs()
            {
                long got = 0;
                while (true)
                {
                    var buf = new MFT_OUTPUT_DATA_BUFFER { dwStreamID = 0, pSample = mftAllocates ? IntPtr.Zero : Marshal.GetIUnknownForObject(ownOut!) };
                    int r;
                    try { r = mft.ProcessOutput(0, 1, ref buf, out _); }
                    finally { if (!mftAllocates && buf.pSample != IntPtr.Zero) Marshal.Release(buf.pSample); }
                    if (r == unchecked((int)MF.NeedMoreInput)) return got;
                    if (r == unchecked((int)MF.StreamChange)) continue;
                    if (r < 0) throw new InvalidOperationException($"ProcessOutput failed (0x{r:X8}).");
                    IMFSample s = mftAllocates ? (IMFSample)Marshal.GetObjectForIUnknown(buf.pSample) : ownOut!;
                    s.GetTotalLength(out uint len);
                    got += len;
                    if (mftAllocates) { Marshal.ReleaseComObject(s); Marshal.Release(buf.pSample); }
                    else ownBuf!.SetCurrentLength(0);
                    if (buf.pEvents != IntPtr.Zero) Marshal.Release(buf.pEvents);
                }
            }

            // input samples are made before the timer (one sample per call is created inside the loop: its cost is part of feeding an encoder)
            double start = Timing.Now();
            for (int i = 0; i < frames.Length; i++)
            {
                MF.MFCreateSample(out var sample);
                MF.MFCreateMemoryBuffer((uint)frameBytes, out var mb);
                mb.Lock(out var p, out _, out _);
                Marshal.Copy(frames[i], 0, p, frameBytes);
                mb.Unlock();
                mb.SetCurrentLength((uint)frameBytes);
                sample.AddBuffer(mb);
                sample.SetSampleTime(i * duration);
                sample.SetSampleDuration(duration);
                int r = mft.ProcessInput(0, sample, 0);
                if (r == unchecked((int)0xC00D36B5)) { outBytes += PullOutputs(); r = mft.ProcessInput(0, sample, 0); }   // MF_E_NOTACCEPTING
                if (r < 0) throw new InvalidOperationException($"ProcessInput failed (0x{r:X8}).");
                Marshal.ReleaseComObject(mb); Marshal.ReleaseComObject(sample);
                outBytes += PullOutputs();
            }
            mft.ProcessMessage(MF.MessageCommandDrain, UIntPtr.Zero);
            outBytes += PullOutputs();
            double seconds = Timing.Now() - start;
            mft.ProcessMessage(MF.MessageEndStreaming, UIntPtr.Zero);
            Marshal.ReleaseComObject(mft);
            return new EncodeResult(frames.Length, seconds, outBytes, note);
        }
        finally { MF.MFShutdown(); }
    }
}
