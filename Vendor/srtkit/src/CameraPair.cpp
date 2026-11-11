#include "srtkit/CameraPair.h"
#include <psa/crypto.h>
extern "C" {
#include <mbedtls/constant_time.h>
}
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <sstream>
#include <stdexcept>
#include <vector>
#include <memory>

namespace srtkit {
namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
using Bytes = std::vector<uint8_t>;
using Error = std::runtime_error;
constexpr auto handshakeTime = std::chrono::seconds(8);
constexpr auto approvalTime = std::chrono::seconds(60);
struct Socket {
    int fd;
    explicit Socket(int fd): fd(fd) {
        if (fd >= 0) {
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
#ifdef SO_NOSIGPIPE
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
        }
    }
    Socket(const Socket&) = delete;
    ~Socket() { if (fd >= 0) close(fd); }
};
void check(psa_status_t status) { if (status != PSA_SUCCESS) throw Error("crypto"); }
std::string hex(const Bytes& bytes) {
    constexpr char digits[] = "0123456789abcdef";
    std::string result;
    for (auto b: bytes) { result += digits[b >> 4]; result += digits[b & 15]; }
    return result;
}
Bytes decode(const std::string& s, size_t size) {
    if (s.size() != 2*size) throw Error("protocol");
    auto digit = [](char c) {
        if (c >= '0' && c <= '9') return c-'0';
        if (c >= 'a' && c <= 'f') return c-'a'+10;
        throw Error("protocol");
    };
    Bytes out(size);
    for (size_t i=0;i<size;i++) out[i]=uint8_t((digit(s[2*i])<<4) | digit(s[2*i+1]));
    return out;
}
const uint8_t* raw(const std::string& text) { return reinterpret_cast<const uint8_t*>(text.data()); }
std::string hash(const std::string& s) {
    Bytes out(32); size_t len=0;
    check(psa_hash_compute(PSA_ALG_SHA_256,raw(s),s.size(),out.data(),out.size(),&len));
    return hex(out);
}
struct Key {
    psa_key_id_t id=0;
    Key() = default;
    Key(const Key&) = delete;
    ~Key() { if(id) psa_destroy_key(id); }
};
std::string mac(const Bytes& k,const std::string& msg) {
    psa_key_attributes_t at=PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&at,PSA_KEY_TYPE_HMAC);
    psa_set_key_usage_flags(&at,PSA_KEY_USAGE_SIGN_MESSAGE);
    psa_set_key_algorithm(&at,PSA_ALG_HMAC(PSA_ALG_SHA_256));
    Key key; check(psa_import_key(&at,k.data(),k.size(),&key.id));
    Bytes out(32); size_t len=0;
    check(psa_mac_compute(key.id,PSA_ALG_HMAC(PSA_ALG_SHA_256),raw(msg),msg.size(),out.data(),out.size(),&len));
    return hex(out);
}
bool same(const std::string& a,const std::string& b) {
    return a.size()==b.size() && mbedtls_ct_memcmp(a.data(),b.data(),a.size())==0;
}
struct Exchange {
    Key key;
    std::string pub;
    Exchange() {
        check(psa_crypto_init());
        psa_key_attributes_t at=PSA_KEY_ATTRIBUTES_INIT;
        psa_set_key_type(&at,PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
        psa_set_key_bits(&at,256); psa_set_key_algorithm(&at,PSA_ALG_ECDH);
        psa_set_key_usage_flags(&at,PSA_KEY_USAGE_DERIVE);
        check(psa_generate_key(&at,&key.id));
        Bytes point(65);size_t len=0;
        check(psa_export_public_key(key.id,point.data(),point.size(),&len));
        pub=hex(point);
    }
    Bytes shared(const std::string& point) {
        auto p=decode(point,65); Bytes keyBytes(32);size_t len=0;
        check(psa_raw_key_agreement(PSA_ALG_ECDH,key.id,p.data(),p.size(),keyBytes.data(),keyBytes.size(),&len));
        return keyBytes;
    }
};
std::string digits(const Bytes& key,const std::string& id) {
    auto value=std::stoul(mac(key,"verify:"+id).substr(0,8),nullptr,16)%1000000;
    char out[7]; std::snprintf(out,sizeof(out),"%06lu",value); return out;
}
bool validName(const std::string& s) {
    return !s.empty() && s.size()<=64 && s.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")==std::string::npos;
}
class Wire {
    int fd; const std::atomic<bool>& stop;
public:
    Wire(int fd,const std::atomic<bool>& stopped):fd(fd),stop(stopped) {}
    void wait(short events,Clock::time_point end) {
        while (!stop) {
            if(Clock::now()>=end) throw Error("timeout");
            pollfd p{fd,events,0};int n=poll(&p,1,100);
            if(n>0 && (p.revents&events)) return;
            if(n>0 || (n<0 && errno!=EINTR))throw Error("disconnected");
        }
        throw Error("cancelled");
    }
    void sendLine(std::string line) {
        line+='\n';size_t offset=0;auto end=Clock::now()+handshakeTime;
        while(offset<line.size()) {
            wait(POLLOUT,end);
#ifdef MSG_NOSIGNAL
            constexpr int flags=MSG_NOSIGNAL;
#else
            constexpr int flags=0;
#endif
            auto n=send(fd,line.data()+offset,line.size()-offset,flags);
            if(n<0 && (errno==EAGAIN||errno==EINTR))continue;
            if(n<=0)throw Error("disconnected");
            offset+=size_t(n);
        }
    }
    std::vector<std::string> read(std::chrono::seconds duration=handshakeTime) {
        auto end=Clock::now()+duration;std::string s;
        while(s.size()<512) {
            wait(POLLIN,end); char c;auto n=recv(fd,&c,1,0);
            if(n<0 && (errno==EAGAIN||errno==EINTR))continue;
            if(n!=1)throw Error("disconnected");
            if(c=='\n') {
                std::istringstream in(s);std::vector<std::string> words;std::string w;
                while(in>>w)words.push_back(w);
                if(words.empty())throw Error("protocol");
                return words;
            }
            if(c<' ' || c>'~')throw Error("protocol");
            s+=c;
        }
        throw Error("protocol");
    }
    void awaitDecisionTick(Clock::time_point end) {
        if(stop)throw Error("cancelled");
        if(Clock::now()>=end)throw Error("timeout");
        pollfd p{fd,POLLIN,0};int n=poll(&p,1,75);
        if(n>0 || (n<0 && errno!=EINTR))throw Error("disconnected");
    }
};
void expect(const std::vector<std::string>& msg,const char* kind,size_t count) {
    if(msg.size()!=count || msg[0]!=kind)throw Error("protocol");
}
std::string commitment(const std::string& pub,const std::string& nonce,const std::string& name) {
    return hash("DTDPAIR1:"+pub+":"+nonce+":"+name);
}
std::string transcript(const std::string& commit,const std::string& offer) { return hash("request:"+commit+":"+offer); }
}
CameraPair::CameraPair(Notify notify):notify_(std::move(notify)) {}
CameraPair::~CameraPair(){stop();}
void CameraPair::stop(){stopped_=true;if(worker_.joinable())worker_.join();}
void CameraPair::decide(const std::string& id,bool allow) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!id.empty() && id==pending_ && !decision_)decision_=allow?1:-1;
}
void CameraPair::mediaReady(const std::string& id,int port) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!id.empty() && id==pending_ && decision_==1)mediaPort_=port>0 && port<=65535?port:-1;
}
void CameraPair::listen(std::string remembered) {
    worker_=std::thread([this, remembered=std::move(remembered)]() mutable {
        try {
            Socket listener(socket(AF_INET6,SOCK_STREAM,0));
            int off=0; sockaddr_in6 addr{};addr.sin6_family=AF_INET6;
            if(listener.fd<0 || setsockopt(listener.fd,IPPROTO_IPV6,IPV6_V6ONLY,&off,sizeof(off)) ||
               bind(listener.fd,reinterpret_cast<sockaddr*>(&addr),sizeof(addr)) || ::listen(listener.fd,4))throw Error("listen");
            socklen_t len=sizeof(addr);
            if(getsockname(listener.fd,reinterpret_cast<sockaddr*>(&addr),&len))throw Error("listen");
            notify_(Listening,"","","",ntohs(addr.sin6_port));
            while(!stopped_) {
                pollfd p{listener.fd,POLLIN,0};
                if(poll(&p,1,100)<=0)continue;
                Socket peer(accept(listener.fd,nullptr,nullptr));
                if(peer.fd>=0)serve(peer.fd,remembered);
            }
        } catch(const std::exception& e){if(!stopped_)notify_(Ended,"","",e.what(),0);}
    });
}
void CameraPair::serve(int fd,std::string& remembered) {
    Wire wire(fd,stopped_);std::string id,name,reason;
    try {
        auto hello=wire.read();expect(hello,"DTDPAIR1",2);decode(hello[1],32);
        Exchange exchange;wire.sendLine("OFFER "+exchange.pub);
        auto open=wire.read();expect(open,"OPEN",5);name=open[3];decode(open[2],16);
        if(!validName(name)||!same(commitment(open[1],open[2],name),hello[1]))throw Error("protocol");
        id=transcript(hello[1],exchange.pub);
        auto shared=exchange.shared(open[1]);
        // DTD Studio keeps one bond per paired camera: `remembered` may hold several, comma separated.
        bool resume=false;std::string matched;
        {
            std::istringstream list(remembered);std::string b;
            while(!resume && std::getline(list,b,',')) {
                if(b.size()==64 && same(open[4],mac(decode(b,32),"resume:"+id))){resume=true;matched=b;}
            }
        }
        auto bond=resume?matched:mac(shared,"bond:"+id);
        {
            std::lock_guard<std::mutex> lock(mutex_);pending_=id;decision_=resume?1:0;mediaPort_=0;
        }
        wire.sendLine(resume?"RESUME":"VERIFY");
        if(!resume)notify_(Verify,id,name,digits(shared,id),0);
        auto end=Clock::now()+approvalTime;
        for(;;) {
            int decision;
            {std::lock_guard<std::mutex> lock(mutex_);decision=decision_;}
            if(decision<0){wire.sendLine("REJECT");throw Error("rejected");}
            if(decision>0)break;
            wire.awaitDecisionTick(end);
        }
        notify_(Authorized,id,name,bond,0);
        end=Clock::now()+handshakeTime;
        int port=0;
        while(!port) {
            {std::lock_guard<std::mutex> lock(mutex_);port=mediaPort_;}
            if(!port)wire.awaitDecisionTick(end);
        }
        if(port<0)throw Error("media");
        if(remembered.find(bond)==std::string::npos) remembered=remembered.empty()?bond:remembered+","+bond;
        auto p=std::to_string(port);
        wire.sendLine("ACCEPT "+p+" "+mac(decode(bond,32),"accept:"+id+":"+p));
    } catch(const std::exception& e){reason=e.what();}
    {std::lock_guard<std::mutex> lock(mutex_);pending_.clear();}
    if(!stopped_)notify_(Ended,id,name,reason,0);
}
void CameraPair::connect(std::string host,int port,std::string name,std::string remembered) {
    worker_=std::thread([this,host,port,name,remembered] {
        try{call(host,port,name,remembered);}
        catch(const std::exception& e){if(!stopped_)notify_(Ended,"","",e.what(),0);}
    });
}
void CameraPair::call(const std::string& host,int port,const std::string& name,const std::string& remembered) {
    if(!validName(name)||port<1||port>65535)throw Error("protocol");
    addrinfo hints{};hints.ai_socktype=SOCK_STREAM;addrinfo* list=nullptr;
    if(getaddrinfo(host.c_str(),std::to_string(port).c_str(),&hints,&list))throw Error("resolve");
    std::unique_ptr<addrinfo,decltype(&freeaddrinfo)> addresses(list,freeaddrinfo);
    std::unique_ptr<Socket> socket;
    for(auto a=list;a && !stopped_;a=a->ai_next) {
        auto candidate=std::make_unique<Socket>(::socket(a->ai_family,SOCK_STREAM,0));
        if(candidate->fd<0)continue;
        if(::connect(candidate->fd,a->ai_addr,a->ai_addrlen)<0) {
            if(errno!=EINPROGRESS)continue;
            try{Wire(candidate->fd,stopped_).wait(POLLOUT,Clock::now()+std::chrono::seconds(4));}
            catch(const Error&){continue;}
            int err=0;socklen_t n=sizeof(err);
            if(getsockopt(candidate->fd,SOL_SOCKET,SO_ERROR,&err,&n)||err)continue;
        }
        socket=std::move(candidate);break;
    }
    if(!socket)throw Error("unreachable");
    Wire wire(socket->fd,stopped_);Exchange exchange;Bytes random(16);check(psa_generate_random(random.data(),random.size()));
    auto nonce=hex(random),commit=commitment(exchange.pub,nonce,name);
    wire.sendLine("DTDPAIR1 "+commit);
    auto offer=wire.read();expect(offer,"OFFER",2);
    auto shared=exchange.shared(offer[1]);auto id=transcript(commit,offer[1]);
    auto proof=remembered.size()==64?mac(decode(remembered,32),"resume:"+id):"-";
    wire.sendLine("OPEN "+exchange.pub+" "+nonce+" "+name+" "+proof);
    auto mode=wire.read();bool resume=mode.size()==1 && mode[0]=="RESUME";
    if(!resume){expect(mode,"VERIFY",1);notify_(Verify,id,"",digits(shared,id),0);}
    if(resume && remembered.size()!=64)throw Error("protocol");
    auto bond=resume?remembered:mac(shared,"bond:"+id);
    auto result=wire.read(approvalTime+handshakeTime);
    if(result.size()==1 && result[0]=="REJECT")throw Error("rejected");
    expect(result,"ACCEPT",3);
    if(result[1].empty()||result[1].size()>5 || result[1].find_first_not_of("0123456789")!=std::string::npos)throw Error("protocol");
    int media=std::stoi(result[1]);
    if(media<1||media>65535||!same(result[2],mac(decode(bond,32),"accept:"+id+":"+result[1])))throw Error("protocol");
    if(!stopped_)notify_(Accepted,id,"",bond,media);
}
}
