use hyper::{
    HeaderMap,
    header::{CONNECTION, HeaderName, TRANSFER_ENCODING},
};

pub fn supported_transfer_encoding(headers: &HeaderMap) -> bool {
    let mut chunked = false;
    for value in headers.get_all(TRANSFER_ENCODING) {
        let Ok(value) = value.to_str() else {
            return false;
        };
        for coding in value.split(',') {
            if chunked
                || !coding
                    .trim_matches([' ', '\t'])
                    .eq_ignore_ascii_case("chunked")
            {
                return false;
            }
            chunked = true;
        }
    }
    true
}

pub fn strip(headers: &mut HeaderMap) {
    let nominated: Vec<_> = headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .filter_map(|name| HeaderName::from_bytes(name.trim().as_bytes()).ok())
        .collect();
    for name in nominated {
        headers.remove(name);
    }
    for name in [
        "connection",
        "proxy-connection",
        "proxy-authorization",
        "proxy-authenticate",
        "keep-alive",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ] {
        headers.remove(name);
    }
}

#[cfg(test)]
mod tests {
    use super::supported_transfer_encoding;
    use hyper::{HeaderMap, header::TRANSFER_ENCODING};

    #[test]
    fn accepts_absent_or_single_chunked_when_header_case_and_ows_vary() {
        for values in [vec![], vec!["chunked"], vec![" \tChUnKeD \t"]] {
            let mut headers = HeaderMap::new();
            for value in values {
                headers.append(TRANSFER_ENCODING, value.parse().unwrap());
            }
            assert!(supported_transfer_encoding(&headers));
        }
    }

    #[test]
    fn rejects_extra_codings_when_tokens_span_values_or_duplicate_fields() {
        for values in [
            vec!["gzip, chunked"],
            vec!["gzip", "chunked"],
            vec!["chunked", "chunked"],
            vec!["chunked, chunked"],
            vec!["chunked;param=1"],
            vec!["chunked,"],
            vec![""],
        ] {
            let mut headers = HeaderMap::new();
            for value in values {
                headers.append(TRANSFER_ENCODING, value.parse().unwrap());
            }
            assert!(!supported_transfer_encoding(&headers));
        }
    }
}
