#include "rate_control.h"

#include <math.h>

namespace rhizo::c2va::enc {

int InitialQp(bool hevc, uint32_t width, uint32_t height, double frame_rate, uint32_t bitrate) {
  if (width == 0 || height == 0 || frame_rate <= 0 || bitrate == 0) return 26;
  const double bpp = bitrate / (static_cast<double>(width) * height * frame_rate);
  const double ref = hevc ? 0.07 : 0.10;
  int qp = static_cast<int>(lround(26.0 - 6.0 * log2(bpp / ref)));
  if (qp < 18) qp = 18;
  if (qp > 45) qp = 45;
  return qp;
}

namespace {

const double kOutlierLog2 = log2(2.5);
const double kIOffsetCbr = 2.0;
const double kIOffsetVbr = 3.0;

int Clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }
double ClampD(double v, double lo, double hi) { return v < lo ? lo : v > hi ? hi : v; }

}

void FrameRateController::Reset(const FrameRcParams& params) {
  params_ = params;
  if (params_.fps <= 0) params_.fps = 30.0;
  if (params_.peak < params_.bitrate) params_.peak = params_.bitrate;
  if (params_.alpha <= 0.1) params_.alpha = kVirglRadeonsiAlpha;
  if (params_.min_qp > params_.max_qp) params_.min_qp = params_.max_qp;
  const int qp0 = Clamp(params_.initial_qp, params_.min_qp, params_.max_qp);
  alpha_ = params_.alpha;
  l_p_ = log2(TargetPerFrame() > 1 ? TargetPerFrame() : 1) + alpha_ * (qp0 - 4) / 6.0;
  l_i_ = l_p_ + 2.0;
  qr_p_ = qr_i_ = qp0;
  prev_p_q_ = -1;
  seen_p_ = seen_i_ = false;
  outliers_p_ = outlier_sign_ = 0;
  buffer_ = peak_buffer_ = 0;
  pending_.clear();
  last_qp_ = last_i_qp_ = last_i_used_qp_ = qp0;
  max_step_ = 2;
  fast_steps_ = 0;
  p_mismatch_ = 0;
  p_locked_ = false;
}

void FrameRateController::SetBitrate(uint32_t bitrate, uint32_t peak) {
  if (bitrate == 0 || bitrate == params_.bitrate) return;
  const double scale = static_cast<double>(bitrate) / params_.bitrate;
  buffer_ *= scale;
  peak_buffer_ *= scale;
  params_.bitrate = bitrate;
  params_.peak = peak < bitrate ? bitrate : peak;
  max_step_ = 6;
}

double FrameRateController::Predict(bool idr, double qp) const {
  return exp2((idr ? l_i_ : l_p_) - alpha_ * (qp - 4) / 6.0);
}

void FrameRateController::SetAlpha(double alpha) {
  l_p_ += (alpha - alpha_) * (qr_p_ - 4) / 6.0;
  l_i_ += (alpha - alpha_) * (qr_i_ - 4) / 6.0;
  alpha_ = alpha;
}

double FrameRateController::SolveQp(double budget, uint32_t n, uint32_t frames_since_idr, bool first_is_idr,
                                    double i_off) const {
  uint32_t n_i = first_is_idr ? 1 : 0;
  if (params_.gop)
    for (uint32_t k = 1; k < n; k++)
      if ((frames_since_idr + k) % params_.gop == 0) n_i++;
  const uint32_t n_p = n - n_i;
  const double sum = n_p * exp2(l_p_) + n_i * exp2(l_i_ + alpha_ * i_off / 6.0);
  if (budget < 1) budget = 1;
  return 4.0 + 6.0 / alpha_ * log2(sum / budget);
}

int FrameRateController::Pick(bool idr, uint32_t frames_since_idr) {
  const double t = TargetPerFrame();
  double b = buffer_, pb = peak_buffer_;
  for (const Pending& p : pending_) {
    b += p.bits - t;
    pb += p.bits - PeakPerFrame();
    if (pb < 0) pb = 0;
  }

  int qp;
  if (p_locked_) {
    if (!idr) {
      qp = last_i_qp_;
    } else {
      const uint32_t n = params_.gop ? params_.gop : static_cast<uint32_t>(params_.fps * 2);
      const double window = params_.vbr ? params_.fps * 2 : 2.0 * n;
      double budget = n * t - b * (n / (window > 2.0 * n ? window : 2.0 * n));
      if (budget < 0.25 * n * t) budget = 0.25 * n * t;
      double q = SolveQp(budget, n, 0, true, 0.0);
      if (params_.vbr) {
        double pbudget = n * PeakPerFrame() - pb;
        if (pbudget < 0.25 * n * t) pbudget = 0.25 * n * t;
        const double qpeak = SolveQp(pbudget, n, 0, true, 0.0);
        if (qpeak > q) q = qpeak;
      }
      const int step = max_step_ > 12 ? max_step_ : 12;
      qp = Clamp(static_cast<int>(lround(q)), last_qp_ - step, last_qp_ + step);
      qp = Clamp(qp, params_.min_qp, params_.max_qp);
      last_qp_ = last_i_qp_ = qp;
      max_step_ = 2;
    }
  } else {
    const double i_off = params_.vbr ? kIOffsetVbr : kIOffsetCbr;
    const uint32_t n = static_cast<uint32_t>(lround(params_.fps * (params_.vbr ? 2.0 : 1.0)));
    const uint32_t w = n < 4 ? 4 : n;
    double budget = w * t - 0.5 * b;
    if (budget < 0.25 * w * t) budget = 0.25 * w * t;
    double q = SolveQp(budget, w, frames_since_idr, idr, i_off);
    if (params_.vbr) {
      const uint32_t n1 = static_cast<uint32_t>(lround(params_.fps)) < 4 ? 4 : static_cast<uint32_t>(lround(params_.fps));
      double pbudget = n1 * PeakPerFrame() - pb;
      if (pbudget < 0.25 * n1 * t) pbudget = 0.25 * n1 * t;
      const double qpeak = SolveQp(pbudget, n1, frames_since_idr, idr, i_off);
      if (qpeak > q) q = qpeak;
    }
    const double size = params_.bitrate * (params_.vbr ? 2.0 : 0.5);
    const bool urgent = params_.vbr ? pb > 0.5 * params_.peak : b > 0.5 * size;
    int down = max_step_, up = max_step_;
    if (fast_steps_ > 0) {
      fast_steps_--;
      if (down < 4) down = 4;
      if (up < 4) up = 4;
    }
    if (urgent && up < 4) up = 4;
    int base = Clamp(static_cast<int>(lround(q)), last_qp_ - down, last_qp_ + up);
    base = Clamp(base, params_.min_qp, params_.max_qp);
    max_step_ = 2;
    last_qp_ = base;
    qp = base;
    if (idr) {
      qp = Clamp(static_cast<int>(lround(base - i_off)), params_.min_qp, params_.max_qp);
      const double cap = params_.vbr ? 0.5 * params_.peak : 0.4 * params_.bitrate;
      while (qp < params_.max_qp && Predict(true, qp) > cap) qp++;
      last_i_qp_ = qp;
    }
  }
  pending_.push_back({idr, qp, Predict(idr, qp)});
  return qp;
}

void FrameRateController::Done(bool idr, int asked_qp, int used_qp, size_t bytes) {
  if (!pending_.empty()) pending_.pop_front();
  const double t = TargetPerFrame();
  const double bits = static_cast<double>(bytes) * 8;
  const double size = params_.bitrate * (params_.vbr ? 2.0 : 0.5);
  buffer_ = ClampD(buffer_ + bits - t, -size, size);
  peak_buffer_ = ClampD(peak_buffer_ + bits - PeakPerFrame(), 0, params_.peak);
  const int q = used_qp >= 0 ? used_qp : asked_qp;

  if (idr) {
    last_i_used_qp_ = q;
  } else if (used_qp >= 0 && used_qp != asked_qp && used_qp == last_i_used_qp_) {
    if (++p_mismatch_ >= 2 && !p_locked_) {
      p_locked_ = true;
      last_qp_ = last_i_qp_;
    }
  } else if (!p_locked_) {
    p_mismatch_ = 0;
  }

  const double lb = log2(bits > 64 ? bits : 64);
  if (idr) {
    const double l = lb + alpha_ * (q - 4) / 6.0;
    l_i_ = seen_i_ ? l_i_ + 0.6 * (l - l_i_) : l;
    qr_i_ = q;
    seen_i_ = true;
    if (!seen_p_) l_p_ = l_i_ - 2.0;
    return;
  }
  if (!seen_p_) {
    l_p_ = lb + alpha_ * (q - 4) / 6.0;
    seen_p_ = true;
    qr_p_ = prev_p_q_ = q;
    prev_p_lb_ = lb;
    return;
  }
  const double l0 = lb + alpha_ * (q - 4) / 6.0;
  const double e_before = outliers_p_ ? l0 - outlier_base_ : l0 - l_p_;
  const bool outlier = fabs(e_before) > kOutlierLog2;
  if (!outlier && prev_p_q_ >= 0 && q != prev_p_q_) {
    const double slope = ClampD(6.0 * (prev_p_lb_ - lb) / (q - prev_p_q_), 0.5, 4.0);
    const double w = ClampD(0.06 * abs(q - prev_p_q_), 0.0, 0.3);
    SetAlpha(ClampD(alpha_ + w * (slope - alpha_), 0.6, 3.5));
  }
  prev_p_lb_ = lb;
  prev_p_q_ = outlier ? -1 : q;
  qr_p_ = q;
  const double l = lb + alpha_ * (q - 4) / 6.0;
  const double e = l - l_p_;
  if (outlier) {
    const int sign = e_before > 0 ? 1 : -1;
    if (outliers_p_ == 0 || sign != outlier_sign_) {
      outliers_p_ = 1;
      outlier_sign_ = sign;
      outlier_base_ = l_p_;
      l_p_ += 0.2 * e;
    } else {
      outliers_p_++;
      if (outliers_p_ == 2) fast_steps_ = 3;
      l_p_ += 0.9 * e;
    }
    return;
  }
  outliers_p_ = 0;
  outlier_sign_ = 0;
  l_p_ += 0.5 * e;
}

}
