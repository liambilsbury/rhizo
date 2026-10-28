#ifndef RHIZO_C2VA_ENC_RATE_CONTROL_H
#define RHIZO_C2VA_ENC_RATE_CONTROL_H

// the starting QP and a frame-level rate controller

#include <stddef.h>
#include <stdint.h>

#include <deque>

namespace rhizo::c2va::enc {

// return the starting QP for a bit rate
int InitialQp(bool hevc, uint32_t width, uint32_t height, double frame_rate, uint32_t bitrate);

constexpr double kVirglRadeonsiAlpha = 1.35;

struct FrameRcParams {
  bool vbr = false;
  double fps = 30.0;
  uint32_t bitrate = 0;
  uint32_t peak = 0;
  uint32_t gop = 0;
  int initial_qp = 26;
  int min_qp = 18;
  int max_qp = 51;
  double alpha = kVirglRadeonsiAlpha;
};

// pick each picture's QP from a size model per picture type
class FrameRateController {
 public:
  void Reset(const FrameRcParams& params);
  // set the bit rate for the next Pick
  void SetBitrate(uint32_t bitrate, uint32_t peak);
  int Pick(bool idr, uint32_t frames_since_idr);
  // drop the last picked picture
  void Unpick() {
    if (!pending_.empty()) pending_.pop_back();
  }
  // update the model from the oldest picture in flight
  void Done(bool idr, int asked_qp, int used_qp, size_t bytes);

  bool p_qp_followed() const { return !p_locked_; }
  uint32_t bitrate() const { return params_.bitrate; }

 private:
  struct Pending {
    bool idr;
    int qp;
    double bits;
  };
  double Predict(bool idr, double qp) const;
  // solve for the base QP at which n pictures fit the budget
  double SolveQp(double budget, uint32_t n, uint32_t frames_since_idr, bool first_is_idr, double i_off) const;
  double TargetPerFrame() const { return params_.bitrate / params_.fps; }
  double PeakPerFrame() const { return params_.peak / params_.fps; }

  FrameRcParams params_;
  // set the size-vs-QP slope
  void SetAlpha(double alpha);

  double alpha_ = kVirglRadeonsiAlpha;
  double l_p_ = 0;
  double l_i_ = 0;
  int qr_p_ = 26;
  int qr_i_ = 26;
  double prev_p_lb_ = 0;
  int prev_p_q_ = -1;
  bool seen_p_ = false;
  bool seen_i_ = false;
  int outliers_p_ = 0;
  int outlier_sign_ = 0;
  double outlier_base_ = 0;
  double buffer_ = 0;
  double peak_buffer_ = 0;
  std::deque<Pending> pending_;
  int last_qp_ = 26;
  int last_i_qp_ = 26;
  int last_i_used_qp_ = 26;
  int max_step_ = 2;
  int fast_steps_ = 0;
  int p_mismatch_ = 0;
  bool p_locked_ = false;
};

}

#endif
