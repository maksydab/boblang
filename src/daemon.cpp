

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <memory>
#include <csignal>
#include <cerrno>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#ifndef AF_UNIX
#define AF_UNIX 1
#endif
typedef SOCKET sock_t;
#define SOCK_INVALID INVALID_SOCKET
#define SOCK_CLOSE(s) closesocket(s)
#define SOCK_UNLINK(p) _unlink(p)
#define SOCK_READ(s, b, n) ::recv((s), (char *)(b), (int)(n), 0)
#define SOCK_WRITE(s, b, n) ::send((s), (const char *)(b), (int)(n), 0)
#define SOCK_STRERR() std::strerror((int)WSAGetLastError())
#define SOCK_SELECT(s) 0
#else
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <sys/time.h>
typedef int sock_t;
#define SOCK_INVALID -1
#define SOCK_CLOSE(s) ::close(s)
#define SOCK_UNLINK(p) ::unlink(p)
#define SOCK_READ(s, b, n) ::read((s), (b), (n))
#define SOCK_WRITE(s, b, n) ::write((s), (b), (n))
#define SOCK_STRERR() std::strerror(errno)
#define SOCK_SELECT(s) ((int)(s) + 1)
#endif
struct daemon_sockaddr {
  short sun_family;
  char sun_path[108];
};

#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/IR/PassInstrumentation.h"
#include "llvm/Passes/OptimizationLevel.h"
#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/Analysis/CGSCCPassManager.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/Host.h"
#include "llvm/TargetParser/Triple.h"
#include "llvm/Support/CodeGen.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/TargetSelect.h"

namespace lld {
namespace elf {
bool link(llvm::ArrayRef<const char *> args, llvm::raw_ostream &stdoutOS,
          llvm::raw_ostream &stderrOS, bool exitEarly, bool disableOutput);
}
}
static const int kIdleTimeoutSec = 120;

class Server {
public:
  Server(const std::string &path);
  ~Server();
  bool valid() const { return sfd_ != SOCK_INVALID; }
  const std::string &error() const { return err_; }
  int acceptLoop();

private:
  bool serve(sock_t fd);
  bool compile(const std::vector<std::string> &args, uint32_t opt_level,
               const std::string &obj, const std::string &ir,
               std::string &detail);

  static bool readExact(sock_t fd, void *dst, size_t n);
  static bool writeExact(sock_t fd, const void *src, size_t n);
  static bool readU32(sock_t fd, uint32_t &v);
  static bool writeU32(sock_t fd, uint32_t v);

  sock_t sfd_ = SOCK_INVALID;
  std::string path_;
  std::string err_;
  std::string target_;
  std::string cpu_;
  std::string features_;
  llvm::TargetMachine *tm_ = nullptr;
  llvm::LLVMContext ctx_;

  Server(const Server &) = delete;
  Server &operator=(const Server &) = delete;
};

Server::Server(const std::string &path) : path_(path) {
  SOCK_UNLINK(path.c_str());

  sfd_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (sfd_ == SOCK_INVALID) {
    err_ = "socket: " + std::string(SOCK_STRERR());
    sfd_ = SOCK_INVALID;
    return;
  }
  struct daemon_sockaddr addr = {};
  addr.sun_family = AF_UNIX;
  if (path.size() >= sizeof(addr.sun_path)) {
    err_ = "socket path too long";
    SOCK_CLOSE(sfd_);
    sfd_ = SOCK_INVALID;
    return;
  }
  std::memcpy(addr.sun_path, path.c_str(), path.size());
  if (::bind(sfd_, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0) {
    err_ = "bind: " + std::string(SOCK_STRERR());
    SOCK_CLOSE(sfd_);
    sfd_ = SOCK_INVALID;
    return;
  }
  if (::listen(sfd_, 16) != 0) {
    err_ = "listen: " + std::string(SOCK_STRERR());
    SOCK_CLOSE(sfd_);
    sfd_ = SOCK_INVALID;
    return;
  }

  target_ = llvm::sys::getDefaultTargetTriple();
  cpu_ = llvm::sys::getHostCPUName().str();
  {
    auto hostFeatures = llvm::sys::getHostCPUFeatures();
    bool first = true;
    for (const auto &f : hostFeatures) {
      if (!first) features_ += ",";
      first = false;
      features_ += (f.second ? "+" : "-");
      features_ += f.getKey().str();
    }
  }

  std::string lookupErr;
  const llvm::Target *theTarget =
      llvm::TargetRegistry::lookupTarget(llvm::Triple(target_), lookupErr);
  if (!theTarget) {
    err_ = "lookupTarget: " + lookupErr;
    SOCK_CLOSE(sfd_);
    sfd_ = SOCK_INVALID;
    return;
  }
  llvm::TargetOptions topts;
  auto rm = std::optional<llvm::Reloc::Model>(llvm::Reloc::PIC_);
  tm_ = theTarget->createTargetMachine(
      llvm::Triple(target_), cpu_, features_, topts, rm, std::nullopt,
      llvm::CodeGenOptLevel::Aggressive);
  if (!tm_) {
    err_ = "createTargetMachine failed";
    SOCK_CLOSE(sfd_);
    sfd_ = SOCK_INVALID;
    return;
  }
}

Server::~Server() {
  delete tm_;
  if (sfd_ != SOCK_INVALID) SOCK_CLOSE(sfd_);
  SOCK_UNLINK(path_.c_str());
}

int Server::acceptLoop() {
  while (true) {
    fd_set rf;
    FD_ZERO(&rf);
    FD_SET(sfd_, &rf);
    struct timeval tv = {kIdleTimeoutSec, 0};
    int r = ::select(SOCK_SELECT(sfd_), &rf, nullptr, nullptr, &tv);
    if (r <= 0) break;
    sock_t cfd = ::accept(sfd_, nullptr, nullptr);
    if (cfd == SOCK_INVALID) continue;
    serve(cfd);
    SOCK_CLOSE(cfd);
  }
  return 0;
}

bool Server::readExact(sock_t fd, void *dst, size_t n) {
  char *p = static_cast<char *>(dst);
  size_t got = 0;
  while (got < n) {
    ssize_t r = SOCK_READ(fd, p + got, n - got);
    if (r <= 0) return false;
    got += static_cast<size_t>(r);
  }
  return true;
}

bool Server::writeExact(sock_t fd, const void *src, size_t n) {
  const char *p = static_cast<const char *>(src);
  size_t sent = 0;
  while (sent < n) {
    ssize_t r = SOCK_WRITE(fd, p + sent, n - sent);
    if (r <= 0) return false;
    sent += static_cast<size_t>(r);
  }
  return true;
}

bool Server::readU32(sock_t fd, uint32_t &v) {
  uint8_t b[4];
  if (!readExact(fd, b, 4)) return false;
  v = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
      ((uint32_t)b[3] << 24);
  return true;
}

bool Server::writeU32(sock_t fd, uint32_t v) {
  uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16),
                  (uint8_t)(v >> 24)};
  return writeExact(fd, b, 4);
}

bool Server::serve(sock_t fd) {
  err_.clear();

  uint32_t nargs = 0;
  if (!readU32(fd, nargs)) return false;
  if (nargs > 1024) nargs = 1024;
  std::vector<std::string> args;
  args.reserve(nargs);
  for (uint32_t i = 0; i < nargs; i++) {
    uint32_t len = 0;
    if (!readU32(fd, len)) return false;
    if (len > (1u << 28)) return false;
    std::string s;
    s.resize(len);
    if (len && !readExact(fd, &s[0], len)) return false;
    args.push_back(std::move(s));
  }

  uint32_t opt_level = 0;
  if (!readU32(fd, opt_level)) return false;
  if (opt_level > 3) opt_level = 2;

  uint32_t objlen = 0;
  if (!readU32(fd, objlen)) return false;
  if (objlen > (1u << 28)) return false;
  std::string obj;
  obj.resize(objlen);
  if (objlen && !readExact(fd, &obj[0], objlen)) return false;

  uint32_t irlen = 0;
  if (!readU32(fd, irlen)) return false;
  if (irlen > (1u << 30)) return false;
  std::string ir;
  ir.resize(irlen);
  if (irlen && !readExact(fd, &ir[0], irlen)) return false;

  uint32_t status = 1;
  std::string detail;
  try {
    if (compile(args, opt_level, obj, ir, detail)) {
      status = 0;
    } else {
      err_ = detail;
    }
  } catch (const std::exception &e) {
    err_ = e.what();
  }

  writeU32(fd, status);
  writeU32(fd, static_cast<uint32_t>(err_.size()));
  if (!err_.empty()) writeExact(fd, err_.data(), err_.size());
  return true;
}

bool Server::compile(const std::vector<std::string> &args, uint32_t opt_level,
                     const std::string &obj, const std::string &ir,
                     std::string &detail) {
  auto mb = llvm::MemoryBuffer::getMemBuffer(
      llvm::StringRef(ir.data(), ir.size()), "boblang", false);
  llvm::SMDiagnostic diag;
  std::unique_ptr<llvm::Module> mod = llvm::parseIR(*mb, diag, ctx_);
  if (!mod) {
    detail = diag.getMessage().str();
    return false;
  }

  mod->setTargetTriple(llvm::Triple(target_));
  mod->setDataLayout(tm_->createDataLayout());

  if (opt_level != 0) {
    llvm::OptimizationLevel ol;
    switch (opt_level) {
      case 1: ol = llvm::OptimizationLevel::O1; break;
      case 3: ol = llvm::OptimizationLevel::O3; break;
      default: ol = llvm::OptimizationLevel::O2; break;
    }
    llvm::PipelineTuningOptions pto;
    llvm::PassInstrumentationCallbacks pic;
    llvm::LoopAnalysisManager lam;
    llvm::FunctionAnalysisManager fam;
    llvm::CGSCCAnalysisManager cgam;
    llvm::ModuleAnalysisManager mam;
    llvm::PassBuilder pb(tm_, pto, std::nullopt, &pic);
    pb.registerLoopAnalyses(lam);
    pb.registerFunctionAnalyses(fam);
    pb.registerCGSCCAnalyses(cgam);
    pb.registerModuleAnalyses(mam);
    pb.crossRegisterProxies(lam, fam, cgam, mam);
    llvm::ModulePassManager mpm = pb.buildPerModuleDefaultPipeline(ol);
    mpm.run(*mod, mam);
  }

  std::error_code ec;
  llvm::raw_fd_ostream dest(obj, ec, llvm::sys::fs::OF_None);
  if (ec) {
    detail = "open object: " + ec.message();
    return false;
  }
  llvm::legacy::PassManager codegen;
  if (tm_->addPassesToEmitFile(codegen, dest, nullptr,
                               llvm::CodeGenFileType::ObjectFile, true)) {
    detail = "addPassesToEmitFile failed";
    return false;
  }
  codegen.run(*mod);
  dest.flush();
  dest.close();

  std::vector<const char *> argv;
  argv.reserve(args.size());
  for (const auto &a : args) argv.push_back(a.c_str());
  llvm::ArrayRef<const char *> passArgs(argv.data(), argv.size());
  if (!lld::elf::link(passArgs, llvm::nulls(), llvm::nulls(), false, false)) {
    detail = "link failed";
    return false;
  }
  return true;
}

int main(int argc, char **argv) {
#ifndef _WIN32
  std::signal(SIGPIPE, SIG_IGN);
#endif
  if (argc < 2) return 1;

#ifdef _WIN32
  WSADATA wsaData;
  if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) return 1;
#endif

  llvm::InitializeAllTargetInfos();
  llvm::InitializeAllTargets();
  llvm::InitializeAllTargetMCs();
  llvm::InitializeAllAsmParsers();
  llvm::InitializeAllAsmPrinters();

  Server server(argv[1]);
  if (!server.valid()) {
    std::fprintf(stderr, "boblangd: %s\n", server.error().c_str());
    return 1;
  }
  return server.acceptLoop();
}
