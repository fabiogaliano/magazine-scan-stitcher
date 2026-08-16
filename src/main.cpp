#include "magstitch/stitcher.hpp"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;

namespace {

void usage() {
    std::cerr
        << "Usage: magstitch A.tif B.tif --output spread.tif [options]\n\n"
        << "Options:\n"
        << "  --rotate-b 180|0\n"
        << "  --model auto|translation|rigid|similarity|affine\n"
        << "  --debug DIR\n"
        << "  --metrics FILE\n"
        << "  --preview FILE       Write a downscaled preview even if alignment is rejected\n"
        << "  --overwrite          Allow replacing an existing final output\n"
        << "  --force              Write final output even when confidence is low\n"
        << "  --help\n";
}

std::string lowerExtension(const fs::path& path) {
    std::string ext = path.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return ext;
}

void ensureParent(const fs::path& path) {
    const auto parent = path.parent_path();
    if (!parent.empty()) fs::create_directories(parent);
}

bool isLosslessOutput(const fs::path& path) {
    const auto ext = lowerExtension(path);
    return ext == ".tif" || ext == ".tiff" || ext == ".png";
}

void writePreview(const cv::Mat& image, const fs::path& path) {
    ensureParent(path);

    cv::Mat preview;
    if (image.depth() == CV_8U) {
        preview = image;
    } else if (image.depth() == CV_16U) {
        image.convertTo(preview, CV_MAKETYPE(CV_8U, image.channels()), 1.0 / 257.0);
    } else {
        image.convertTo(preview, CV_MAKETYPE(CV_8U, image.channels()));
    }

    constexpr int kMaxDimension = 2400;
    const int longest = std::max(preview.cols, preview.rows);
    if (longest > kMaxDimension) {
        const double scale = static_cast<double>(kMaxDimension) / longest;
        cv::Mat resized;
        cv::resize(preview, resized, cv::Size(), scale, scale, cv::INTER_AREA);
        preview = resized;
    }

    std::vector<int> params;
    const auto ext = lowerExtension(path);
    if (ext == ".jpg" || ext == ".jpeg") params = {cv::IMWRITE_JPEG_QUALITY, 90};
    else if (ext == ".png") params = {cv::IMWRITE_PNG_COMPRESSION, 3};

    if (!cv::imwrite(path.string(), preview, params)) {
        throw std::runtime_error("failed to write preview " + path.string());
    }
}

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc < 2) { usage(); return 2; }
        if (std::string(argv[1]) == "--help") { usage(); return 0; }
        if (argc < 5) { usage(); return 2; }

        fs::path a_path = argv[1], b_path = argv[2], output_path;
        std::optional<fs::path> debug_dir, metrics_path, preview_path;
        magstitch::StitchOptions options;
        bool overwrite = false;

        for (int i = 3; i < argc; ++i) {
            const std::string arg = argv[i];
            auto need = [&](const char* flag) -> std::string {
                if (i + 1 >= argc) throw std::invalid_argument(std::string("missing value for ") + flag);
                return argv[++i];
            };
            if (arg == "--output") output_path = need("--output");
            else if (arg == "--debug") debug_dir = fs::path(need("--debug"));
            else if (arg == "--metrics") metrics_path = fs::path(need("--metrics"));
            else if (arg == "--preview") preview_path = fs::path(need("--preview"));
            else if (arg == "--model") options.model = magstitch::Stitcher::parseModel(need("--model"));
            else if (arg == "--rotate-b") {
                const auto v = need("--rotate-b");
                if (v == "180") options.rotate_b_180 = true;
                else if (v == "0") options.rotate_b_180 = false;
                else throw std::invalid_argument("--rotate-b must be 180 or 0");
            } else if (arg == "--overwrite") overwrite = true;
            else if (arg == "--force") options.force = true;
            else if (arg == "--help") { usage(); return 0; }
            else throw std::invalid_argument("unknown argument: " + arg);
        }

        if (output_path.empty()) throw std::invalid_argument("--output is required");
        if (!isLosslessOutput(output_path)) {
            throw std::invalid_argument("final output must be TIFF or PNG; use --preview for JPEG inspection");
        }
        if (fs::exists(output_path) && !overwrite) {
            throw std::invalid_argument("output already exists; pass --overwrite to replace it");
        }

        cv::Mat a = cv::imread(a_path.string(), cv::IMREAD_UNCHANGED);
        cv::Mat b = cv::imread(b_path.string(), cv::IMREAD_UNCHANGED);
        if (a.empty()) throw std::runtime_error("failed to read " + a_path.string());
        if (b.empty()) throw std::runtime_error("failed to read " + b_path.string());

        magstitch::Stitcher stitcher(options);
        auto result = stitcher.stitch(a, b, debug_dir);
        const std::string json = magstitch::Stitcher::metricsJson(result.metrics);
        std::cout << json << '\n';

        if (metrics_path) {
            ensureParent(*metrics_path);
            std::ofstream f(*metrics_path);
            if (!f) throw std::runtime_error("failed to open metrics output");
            f << json << '\n';
        }

        if (preview_path) writePreview(result.image, *preview_path);

        if (!result.accepted && !options.force) {
            std::cerr << "Automatic alignment uncertain; final output was not written."
                      << (preview_path ? " Inspect the preview and diagnostics." : " Use --preview to inspect the result.")
                      << "\n";
            return 4;
        }

        ensureParent(output_path);
        std::vector<int> params;
        if (lowerExtension(output_path) == ".png") params = {cv::IMWRITE_PNG_COMPRESSION, 3};
        if (!cv::imwrite(output_path.string(), result.image, params)) {
            throw std::runtime_error("failed to write output image");
        }
        return result.accepted ? 0 : 5;
    } catch (const std::invalid_argument& e) {
        std::cerr << "magstitch: " << e.what() << '\n';
        return 2;
    } catch (const std::exception& e) {
        std::cerr << "magstitch: " << e.what() << '\n';
        return 3;
    }
}
