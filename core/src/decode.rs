use chardetng::EncodingDetector;
use encoding_rs::{Encoding, GB18030, UTF_16BE, UTF_16LE, UTF_8};

pub struct Decoded {
    pub encoding: &'static str,
    /// Newlines normalised to \n, BOM stripped. Full-width spaces preserved:
    /// they carry the paragraph-indent signal the rest of the pipeline relies on.
    pub text: String,
}

pub fn decode(raw: &[u8]) -> Decoded {
    let (enc, body): (&'static Encoding, &[u8]) = match raw {
        [0xFF, 0xFE, rest @ ..] => (UTF_16LE, rest),
        [0xFE, 0xFF, rest @ ..] => (UTF_16BE, rest),
        [0xEF, 0xBB, 0xBF, rest @ ..] => (UTF_8, rest),
        _ if std::str::from_utf8(raw).is_ok() => (UTF_8, raw),
        _ => {
            let mut det = EncodingDetector::new();
            det.feed(raw, true);
            // Chinese TXT in the wild is overwhelmingly GB18030; only trust the
            // detector when it is confident enough to name a legacy encoding.
            let guess = det.guess(None, true);
            let enc = if guess == UTF_8 { GB18030 } else { guess };
            (enc, raw)
        }
    };

    finish(enc, body)
}

/// Decode with a user-chosen encoding, bypassing all sniffing. The escape hatch
/// for when detection guesses wrong: a Big5 file that decodes "fine" as GB18030
/// produces fluent-looking garbage no detector can flag.
pub fn decode_as(raw: &[u8], label: &str) -> Option<Decoded> {
    let enc = Encoding::for_label(label.as_bytes())?;
    // A BOM matching the chosen encoding is a marker, not text.
    let body = match raw {
        [0xFF, 0xFE, rest @ ..] if enc == UTF_16LE => rest,
        [0xFE, 0xFF, rest @ ..] if enc == UTF_16BE => rest,
        [0xEF, 0xBB, 0xBF, rest @ ..] if enc == UTF_8 => rest,
        _ => raw,
    };
    Some(finish(enc, body))
}

fn finish(enc: &'static Encoding, body: &[u8]) -> Decoded {
    let (cow, _) = enc.decode_without_bom_handling(body);
    let mut text = cow.into_owned();
    if text.contains('\r') {
        text = text.replace("\r\n", "\n").replace('\r', "\n");
    }
    Decoded {
        encoding: enc.name(),
        text,
    }
}
