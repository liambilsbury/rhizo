#pragma once
#include <android/binder_ibinder.h>
#include <android/binder_auto_utils.h>
#include <algorithm>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

namespace rhizo_wifi {

// binder callbacks deduped by binder and dropped on death
template <typename T>
class CallbackList {
 public:
  CallbackList() : inner_(std::make_shared<Inner>()) {
    recipient_ = AIBinder_DeathRecipient_new(OnDied);
    AIBinder_DeathRecipient_setOnUnlinked(recipient_, OnUnlinked);
  }
  ~CallbackList() {
    Clear();
    AIBinder_DeathRecipient_delete(recipient_);
  }
  CallbackList(const CallbackList&) = delete;
  CallbackList& operator=(const CallbackList&) = delete;

  // set the function called when a callback's process dies
  void OnDeath(std::function<void(size_t)> fn) {
    std::lock_guard<std::mutex> lg(inner_->mu);
    inner_->on_death = std::move(fn);
  }

  // add a callback unless its binder is already held
  void Add(const std::shared_ptr<T>& cb) {
    if (!cb) return;
    AIBinder* b = cb->asBinder().get();
    std::lock_guard<std::mutex> lg(inner_->mu);
    for (auto& e : inner_->list) {
      if (e.binder == b) return;
    }
    Entry e{cb, b, nullptr};
    if (AIBinder_isRemote(b)) {
      e.cookie = new Cookie{inner_, b};
      if (AIBinder_linkToDeath(b, recipient_, e.cookie) != STATUS_OK) e.cookie = nullptr;
    }
    inner_->list.push_back(std::move(e));
  }

  // drop all of the callbacks
  void Clear() {
    std::vector<Entry> old;
    {
      std::lock_guard<std::mutex> lg(inner_->mu);
      old.swap(inner_->list);
    }
    for (auto& e : old) {
      if (e.cookie) AIBinder_unlinkToDeath(e.binder, recipient_, e.cookie);
    }
  }

  // call fn on a snapshot of the callbacks
  void ForEach(const std::function<void(const std::shared_ptr<T>&)>& fn) const {
    std::vector<std::shared_ptr<T>> snap;
    {
      std::lock_guard<std::mutex> lg(inner_->mu);
      for (auto& e : inner_->list) snap.push_back(e.cb);
    }
    for (auto& cb : snap) fn(cb);
  }

  size_t Size() const {
    std::lock_guard<std::mutex> lg(inner_->mu);
    return inner_->list.size();
  }

 private:
  struct Inner;
  struct Cookie {
    std::weak_ptr<Inner> inner;
    AIBinder* binder;
  };
  struct Entry {
    std::shared_ptr<T> cb;
    AIBinder* binder;
    Cookie* cookie;
  };
  struct Inner {
    mutable std::mutex mu;
    std::vector<Entry> list;
    std::function<void(size_t)> on_death;
  };

  // drop the dead callback and report the count left
  static void OnDied(void* cookie) {
    auto* c = static_cast<Cookie*>(cookie);
    auto inner = c->inner.lock();
    if (!inner) return;
    std::function<void(size_t)> fn;
    size_t left;
    std::shared_ptr<T> dead;
    {
      std::lock_guard<std::mutex> lg(inner->mu);
      auto it = std::find_if(inner->list.begin(), inner->list.end(),
                             [&](const Entry& e) { return e.cookie == c; });
      if (it == inner->list.end()) return;
      dead = it->cb;
      inner->list.erase(it);
      left = inner->list.size();
      fn = inner->on_death;
    }
    if (fn) fn(left);
  }

  // free a cookie once its link is gone
  static void OnUnlinked(void* cookie) { delete static_cast<Cookie*>(cookie); }

  std::shared_ptr<Inner> inner_;
  AIBinder_DeathRecipient* recipient_;
};

}
