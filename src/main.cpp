#include "magstitch/stitcher.hpp"

#include <opencv2/imgcodecs.hpp>

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
        << "  --force\n"
        << "  --help\n";
}

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc < 2) { usage(); return 2; }
        if (std::string(argv[1]) == "--help") { usage(); return 0; }
        if (argc < 5) { usage(); return 2; }

        fs::path a_path = argv[1], b_path = argv[2], output_path;
        std::optional<fs::path> debug_dir, metrics_path;
        magstitch::StitchOptions options;

        for (int i = 3; i < argc; ++i) {
            const std::string arg = argv[i];
            auto need = [&](const char* flag) -> std::string {
                if (i + 1 >= argc) throw std::invalid_argument(std::string("missing value for ") + flag);
                return argv[++i];
            };
            if (arg == "--output") output_path = need("--output");
            else if (arg == "--debug") debug_dir = fs::path(need("--debug"));
            else if (arg == "--metrics") metrics_path = fs::path(need("--metrics"));
            else if (arg == "--model") options.model = magstitch::Stitcher::parseModel(need("--model"));
            else if (arg == "--rotate-b") {
                const auto v = need("--rotate-b");
                if (v == "180") options.rotate_b_180 = true;
                else if (v == "0") options.rotate_b_180 = false;
                else throw std::invalid_argument("--rotate-b must be 180 or 0");
            } else if (arg == "--force") options.force = true;
            else if (arg == "--help") { usage(); return 0; }
            else throw std::invalid_argument("unknown argument: " + arg);
        }
        if (output_path.empty()) throw std::invalid_argument("--output is required");

        cv::Mat a = cv::imread(a_path.string(), cv::IMREAD_UNCHANGED);
        cv::Mat b = cv::imread(b_path.string(), cv::IMREAD_UNCHANGED);
        if (a.empty()) throw std::runtime_error("failed to read " + a_path.string());
        if (b.empty()) throw std::runtime_error("failed to read " + b_path.string());

        magstitch::Stitcher stitcher(options);
        auto result = stitcher.stitch(a, b, debug_dir);
        const std::string json = magstitch::Stitcher::metricsJson(result.metrics);
        std::cout << json << '\n';

        if (metrics_path) {
            std::ofstream f(*metrics_path);
            if (!f) throw std::runtime_error("failed to open metrics output");
            f << json << '\n';
        }

        if (!result.accepted && !options.force) {
            std::cerr << "Automatic alignment uncertain; refusing archival output. Use --force to override.\n";
            return 4;
        }

        std::vector<int> params;
        const auto ext = output_path.extension().string();
        if (ext == ".png" || ext == ".PNG") params = {cv::IMWRITE_PNG_COMPRESSION, 3};
        if (!cv::imwrite(output_path.string(), result.image, params)) {
            throw std::runtime_error("failed to write output image");
        }
        return result.accepted ? 0 : 5;
    } catch (const std::exception& e) {
        std::cerr << "magstitch: " << e.what() << '\n';
        return 3;
    }
}
