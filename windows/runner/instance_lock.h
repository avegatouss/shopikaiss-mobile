#ifndef SHOPIKAISS_INSTANCE_LOCK_H_
#define SHOPIKAISS_INSTANCE_LOCK_H_
#include <windows.h>

// An additional engine-owned database lock is still required by session B.
class InstanceLock {
 public:
  InstanceLock() = default;
  InstanceLock(const InstanceLock&) = delete;
  InstanceLock& operator=(const InstanceLock&) = delete;
  ~InstanceLock() { if (handle_) CloseHandle(handle_); }
  bool Acquire();
 private:
  HANDLE handle_ = nullptr;
};
#endif
