#pragma once

#include <opencv2/core.hpp>

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace magstitch {

enum class Model { Auto, Translation, Rigid, Similarity, Affine };

struct StitchOptions {
    Model model = Model::Auto;
    bool rotate_b_180 = true;
    bool force = false;
    double work_megapixels = 2.0;
    double ratio_test = 0.72;
    double ransac_reproj_threshold = 3.0;
    int min_inliers = 18;
    double min_inlier_ratio = 0.20;
    double min_scale = 0.97;
    double max_scale = 1.03;
    double max_abs_rotation_deg = 4.0;
    int feather_width = 8;
};

struct Metrics {
    int keypoints_a = 0;
    int keypoints_b = 0;
    int candidate_matches = 0;
    int mutual_matches = 0;
    int inliers = 0;
    double inlier_ratio = 0.0;
    double median_reprojection_error = 0.0;
    double p90_reprojection_error = 0.0;
    double rotation_deg = 0.0;
    double scale_x = 1.0;
    double scale_y = 1.0;
    double shear = 0.0;
    double translation_x = 0.0;
    double translation_y = 0.0;
    double overlap_fraction = 0.0;
    double residual_before = 0.0;
    double residual_after = 0.0;
    double improvement = 0.0;
    double seam_mean_cost = 0.0;
    int confidence = 0;
    std::string selected_model;
    std::vector<std::string> rejection_reasons;
};

struct StitchResult {
    cv::Mat image;
    cv::Mat transform_b_to_a;
    Metrics metrics;
    bool accepted = false;
};

class Stitcher {
public:
    explicit Stitcher(StitchOptions options = {});

    StitchResult stitch(const cv::Mat& a, const cv::Mat& b,
                        const std::optional<std::filesystem::path>& debug_dir = std::nullopt) const;

    static Model parseModel(const std::string& value);
    static std::string modelName(Model model);
    static std::string metricsJson(const Metrics& metrics);

private:
    StitchOptions options_;
};

} // namespace magstitch
