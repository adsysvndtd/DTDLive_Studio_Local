#pragma once
#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace srtkit {
// Callbacks run on the socket worker. UI decisions must echo the request ID.
class CameraPair {
public:
    enum Event { Listening, Verify, Authorized, Accepted, Ended };
    using Notify = std::function<void(Event, const std::string& id, const std::string& peer,
                                      const std::string& value, int port)>;
    explicit CameraPair(Notify notify);
    ~CameraPair();
    void listen(std::string remembered);
    void connect(std::string host, int port, std::string name, std::string remembered);
    void decide(const std::string& id, bool allow);
    void mediaReady(const std::string& id, int port);
    void stop();
private:
    void serve(int fd, std::string& remembered);
    void call(const std::string& host, int port, const std::string& name, const std::string& remembered);
    Notify notify_;
    std::thread worker_;
    std::atomic<bool> stopped_{false};
    std::mutex mutex_;
    std::string pending_;
    int decision_ = 0;
    int mediaPort_ = 0;
};
}
