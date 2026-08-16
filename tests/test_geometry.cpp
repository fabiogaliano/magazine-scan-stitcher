#include "magstitch/stitcher.hpp"

#include <opencv2/imgproc.hpp>

#include <cassert>
#include <cmath>
#include <iostream>

namespace {

cv::Mat syntheticPage() {
    cv::Mat img(900, 1400, CV_8UC3, cv::Scalar(245,245,245));
    cv::RNG rng(12345);
    for (int y = 60; y < 840; y += 28) {
        for (int x = 45; x < 1350; x += 70) {
            const int shade = 20 + rng.uniform(0, 80);
            cv::rectangle(img, cv::Rect(x, y, rng.uniform(25, 60), 3), cv::Scalar(shade, shade, shade), cv::FILLED);
        }
    }
    for (int i = 0; i < 80; ++i) {
        cv::circle(img, cv::Point(rng.uniform(20, 1380), rng.uniform(20, 880)), rng.uniform(2, 8),
                   cv::Scalar(rng.uniform(0,255), rng.uniform(0,255), rng.uniform(0,255)), cv::FILLED);
    }
    cv::putText(img, "MAGAZINE 1978", cv::Point(360, 470), cv::FONT_HERSHEY_SIMPLEX, 2.2,
                cv::Scalar(30,30,30), 4, cv::LINE_AA);
    return img;
}

void testSimilarityRecovery() {
    cv::Mat page = syntheticPage();
    cv::Mat a = page(cv::Rect(0, 0, 900, 900)).clone();
    cv::Mat b_source = page(cv::Rect(500, 0, 900, 900)).clone();

    const double angle = 0.6 * CV_PI / 180.0;
    const double scale = 1.002;
    cv::Mat m = (cv::Mat_<double>(2,3) << scale*std::cos(angle), -scale*std::sin(angle), 7.0,
                                             scale*std::sin(angle),  scale*std::cos(angle), -5.0);
    cv::Mat b;
    cv::warpAffine(b_source, b, m, b_source.size(), cv::INTER_LINEAR, cv::BORDER_REFLECT);

    magstitch::StitchOptions opts;
    opts.rotate_b_180 = false;
    opts.model = magstitch::Model::Similarity;
    opts.work_megapixels = 1.0;
    opts.min_inliers = 8;
    opts.min_inlier_ratio = 0.08;
    opts.min_scale = 0.95;
    opts.max_scale = 1.05;
    opts.max_abs_rotation_deg = 5.0;

    auto r = magstitch::Stitcher(opts).stitch(a, b);
    assert(r.metrics.inliers >= 8);
    assert(r.metrics.overlap_fraction > 0.20);
    assert(std::abs(r.metrics.scale_x - 1.0/scale) < 0.015);
    assert(std::abs(r.metrics.rotation_deg + 0.6) < 0.5);
    assert(!r.image.empty());
}

void testModelParsing() {
    assert(magstitch::Stitcher::parseModel("auto") == magstitch::Model::Auto);
    assert(magstitch::Stitcher::parseModel("affine") == magstitch::Model::Affine);
}

} // namespace

int main() {
    testModelParsing();
    testSimilarityRecovery();
    std::cout << "geometry tests passed\n";
    return 0;
}
