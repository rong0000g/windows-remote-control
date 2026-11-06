"""SenseVoice recognition worker started by dictate.exe.
Protocol over stdin and stdout, one UTF-8 line each: prints READY after loading, then for every
WAV path received prints TEXT <recognized text> or ERR <message>. Exits when stdin closes, which
is how dictate.exe releases the model's memory.
Usage: python -I asr_worker.py <model dir> <library dir>
"""
import struct, sys, wave

out = sys.stdout.buffer


def say(line):
    out.write((line.replace("\r", " ").replace("\n", " ") + "\n").encode("utf-8"))
    out.flush()


def recognize(rec, path):
    with wave.open(path, "rb") as w:
        rate, raw = w.getframerate(), w.readframes(w.getnframes())
    stream = rec.create_stream()
    stream.accept_waveform(rate, [v / 32768.0 for v in struct.unpack("<%dh" % (len(raw) // 2), raw)])
    rec.decode_stream(stream)
    return stream.result.text


def main():
    model_dir, pylib = sys.argv[1], sys.argv[2]
    sys.path.insert(0, pylib)
    try:
        import sherpa_onnx
        rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=model_dir + "/model.int8.onnx", tokens=model_dir + "/tokens.txt",
            language="zh", use_itn=True, num_threads=4)
    except Exception as e:
        say("ERR " + type(e).__name__)
        return
    say("READY")
    for line in sys.stdin.buffer:
        path = line.decode("utf-8").strip()
        if not path:
            continue
        try:
            say("TEXT " + recognize(rec, path))
        except Exception as e:
            say("ERR " + type(e).__name__)


if __name__ == "__main__":
    main()
