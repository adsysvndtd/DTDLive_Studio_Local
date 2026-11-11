#include <cstdlib>
#include <map>

#include "srtkit/Types.h"

namespace srtkit {

namespace {
std::string urlDecode(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size()) {
            out.push_back(static_cast<char>(std::strtol(s.substr(i + 1, 2).c_str(), nullptr, 16)));
            i += 2;
        } else if (s[i] == '+') {
            out.push_back(' ');
        } else {
            out.push_back(s[i]);
        }
    }
    return out;
}
} // namespace

bool parseSrtUrl(const std::string& url, SrtOptions& o, std::string* err) {
    auto fail = [&](const char* m) { if (err) *err = m; return false; };
    const std::string scheme = "srt://";
    if (url.compare(0, scheme.size(), scheme) != 0) return fail("URL phải bắt đầu bằng srt://");
    std::string rest = url.substr(scheme.size());
    std::string query;
    size_t q = rest.find('?');
    if (q != std::string::npos) { query = rest.substr(q + 1); rest = rest.substr(0, q); }
    while (!rest.empty() && rest.back() == '/') rest.pop_back();

    std::string host, port;
    if (!rest.empty() && rest[0] == '[') {
        size_t e = rest.find(']');
        if (e == std::string::npos) return fail("IPv6 thiếu ]");
        host = rest.substr(1, e - 1);
        if (e + 1 < rest.size() && rest[e + 1] == ':') port = rest.substr(e + 2);
    } else {
        size_t c = rest.rfind(':');
        if (c == std::string::npos) return fail("thiếu cổng");
        host = rest.substr(0, c);
        port = rest.substr(c + 1);
    }
    o.host = host;
    o.port = std::atoi(port.c_str());
    if (o.port <= 0 || o.port > 65535) return fail("cổng không hợp lệ");

    std::map<std::string, std::string> kv;
    size_t i = 0;
    while (i <= query.size() && !query.empty()) {
        size_t amp = query.find('&', i);
        std::string part = query.substr(i, amp == std::string::npos ? std::string::npos : amp - i);
        size_t eq = part.find('=');
        if (eq != std::string::npos) kv[part.substr(0, eq)] = urlDecode(part.substr(eq + 1));
        if (amp == std::string::npos) break;
        i = amp + 1;
    }
    auto get = [&](std::initializer_list<const char*> keys) -> const std::string* {
        for (auto k : keys) { auto it = kv.find(k); if (it != kv.end()) return &it->second; }
        return nullptr;
    };
    if (auto v = get({"mode", "srtmode"})) {
        const std::string& m = *v;
        if (m == "caller" || m == "client" || m == "c") o.mode = SrtMode::Caller;
        else if (m == "listener" || m == "server" || m == "l") o.mode = SrtMode::Listener;
        else if (m == "rendezvous" || m == "r") o.mode = SrtMode::Rendezvous;
        else return fail("mode không hợp lệ");
    }
    if (auto v = get({"latency", "srtlatency"})) o.latencyMs = std::atoi(v->c_str());
    if (auto v = get({"maxbw", "srtmaxbw"})) o.maxBwBytesPerSec = std::atoll(v->c_str());
    if (auto v = get({"passphrase", "srtpass"})) o.passphrase = *v;
    if (auto v = get({"pbkeylen", "srtpbkl"})) o.pbKeyLen = std::atoi(v->c_str());
    if (auto v = get({"streamid", "srtstreamid"})) o.streamId = *v;
    if (auto v = get({"conntimeo"})) o.connectTimeoutMs = std::atoi(v->c_str());
    if (auto v = get({"localport", "port_local"})) o.localPort = std::atoi(v->c_str());

    if (!o.passphrase.empty() && (o.passphrase.size() < 10 || o.passphrase.size() > 79))
        return fail("passphrase phải dài 10..79 ký tự");
    if (o.pbKeyLen != 16 && o.pbKeyLen != 24 && o.pbKeyLen != 32) return fail("pbkeylen phải là 16, 24 hoặc 32");
    if (o.latencyMs < 20 || o.latencyMs > 8000) return fail("latency nằm ngoài 20..8000 ms");
    if (o.streamId.size() > 512) return fail("streamid quá 512 ký tự");
    return true;
}

} // namespace srtkit
