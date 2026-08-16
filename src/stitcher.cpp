#include "magstitch/stitcher.hpp"

#include <opencv2/calib3d.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <limits>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <unordered_map>

namespace fs = std::filesystem;

namespace magstitch {
namespace {

constexpr double kPi = 3.14159265358979323846;

cv::Mat toGray8(const cv::Mat& src) {
    cv::Mat gray;
    if (src.channels() == 1) gray = src;
    else if (src.channels() == 3) cv::cvtColor(src, gray, cv::COLOR_BGR2GRAY);
    else if (src.channels() == 4) cv::cvtColor(src, gray, cv::COLOR_BGRA2GRAY);
    else throw std::runtime_error("unsupported channel count");
    if (gray.depth() == CV_8U) return gray;
    double minv = 0.0, maxv = 0.0;
    cv::minMaxLoc(gray, &minv, &maxv);
    cv::Mat out;
    if (maxv <= minv) gray.convertTo(out, CV_8U);
    else gray.convertTo(out, CV_8U, 255.0 / (maxv - minv), -minv * 255.0 / (maxv - minv));
    return out;
}

cv::Mat normalizeChannelsAndDepth(const cv::Mat& src, const cv::Mat& reference) {
    cv::Mat channels;
    if (src.channels() == reference.channels()) channels = src;
    else if (src.channels() == 4 && reference.channels() == 3) cv::cvtColor(src, channels, cv::COLOR_BGRA2BGR);
    else if (src.channels() == 3 && reference.channels() == 4) cv::cvtColor(src, channels, cv::COLOR_BGR2BGRA);
    else if (src.channels() == 1 && reference.channels() == 3) cv::cvtColor(src, channels, cv::COLOR_GRAY2BGR);
    else if (src.channels() == 1 && reference.channels() == 4) cv::cvtColor(src, channels, cv::COLOR_GRAY2BGRA);
    else throw std::runtime_error("input images have incompatible channel counts");
    if (channels.depth() == reference.depth()) return channels;
    cv::Mat out;
    channels.convertTo(out, CV_MAKETYPE(reference.depth(), reference.channels()));
    return out;
}

struct WorkImage { cv::Mat gray; double scale = 1.0; };

WorkImage makeWorkImage(const cv::Mat& src, double megapixels) {
    const double pixels = static_cast<double>(src.cols) * src.rows;
    const double target = std::max(0.1, megapixels) * 1'000'000.0;
    const double scale = pixels > target ? std::sqrt(target / pixels) : 1.0;
    cv::Mat gray = toGray8(src), work;
    if (scale < 0.999) cv::resize(gray, work, cv::Size(), scale, scale, cv::INTER_AREA);
    else work = gray;
    return {work, scale};
}

struct MatchSet {
    std::vector<cv::KeyPoint> keypoints_a;
    std::vector<cv::KeyPoint> keypoints_b;
    std::vector<cv::DMatch> mutual;
    int candidate_matches = 0;
};

MatchSet matchSift(const cv::Mat& a, const cv::Mat& b, double ratio) {
    auto sift = cv::SIFT::create(5000);
    MatchSet result;
    cv::Mat da, db;
    sift->detectAndCompute(a, cv::noArray(), result.keypoints_a, da);
    sift->detectAndCompute(b, cv::noArray(), result.keypoints_b, db);
    if (da.empty() || db.empty()) return result;
    cv::BFMatcher matcher(cv::NORM_L2, false);
    std::vector<std::vector<cv::DMatch>> ab, ba;
    matcher.knnMatch(da, db, ab, 2);
    matcher.knnMatch(db, da, ba, 2);
    std::unordered_map<int, int> good_ba;
    for (const auto& pair : ba) {
        if (pair.size() >= 2 && pair[0].distance < ratio * pair[1].distance)
            good_ba[pair[0].queryIdx] = pair[0].trainIdx;
    }
    for (const auto& pair : ab) {
        if (pair.size() < 2 || pair[0].distance >= ratio * pair[1].distance) continue;
        ++result.candidate_matches;
        auto it = good_ba.find(pair[0].trainIdx);
        if (it != good_ba.end() && it->second == pair[0].queryIdx) result.mutual.push_back(pair[0]);
    }
    return result;
}

std::vector<cv::Point2f> pointsFromMatches(const std::vector<cv::KeyPoint>& kps,
                                           const std::vector<cv::DMatch>& matches,
                                           bool query) {
    std::vector<cv::Point2f> pts;
    pts.reserve(matches.size());
    for (const auto& m : matches) pts.push_back(kps[query ? m.queryIdx : m.trainIdx].pt);
    return pts;
}

cv::Mat scaleTransformToFull(const cv::Mat& m, double scale_a, double scale_b) {
    cv::Mat out;
    m.convertTo(out, CV_64F);
    out.at<double>(0, 0) *= scale_b / scale_a;
    out.at<double>(0, 1) *= scale_b / scale_a;
    out.at<double>(1, 0) *= scale_b / scale_a;
    out.at<double>(1, 1) *= scale_b / scale_a;
    out.at<double>(0, 2) /= scale_a;
    out.at<double>(1, 2) /= scale_a;
    return out;
}

cv::Mat estimateTransform(const std::vector<cv::Point2f>& pts_b,
                          const std::vector<cv::Point2f>& pts_a,
                          Model model, double threshold, cv::Mat& inlier_mask) {
    if (model == Model::Affine)
        return cv::estimateAffine2D(pts_b, pts_a, inlier_mask, cv::RANSAC, threshold, 2000, 0.99, 10);
    cv::Mat sim = cv::estimateAffinePartial2D(pts_b, pts_a, inlier_mask, cv::RANSAC, threshold, 2000, 0.99, 10);
    if (sim.empty()) return sim;
    sim.convertTo(sim, CV_64F);
    const double a = sim.at<double>(0,0), c = sim.at<double>(1,0);
    const double scale = std::sqrt(a*a + c*c);
    (void)scale;
    const double angle = std::atan2(c, a);
    const double tx = sim.at<double>(0,2), ty = sim.at<double>(1,2);
    if (model == Model::Translation) return (cv::Mat_<double>(2,3) << 1.0,0.0,tx, 0.0,1.0,ty);
    if (model == Model::Rigid) {
        const double ca = std::cos(angle), sa = std::sin(angle);
        return (cv::Mat_<double>(2,3) << ca,-sa,tx, sa,ca,ty);
    }
    return sim;
}

void decompose(const cv::Mat& m, Metrics& metrics) {
    const double a = m.at<double>(0,0), b = m.at<double>(0,1);
    const double c = m.at<double>(1,0), d = m.at<double>(1,1);
    metrics.scale_x = std::sqrt(a*a + c*c);
    metrics.scale_y = std::sqrt(b*b + d*d);
    metrics.rotation_deg = std::atan2(c, a) * 180.0 / kPi;
    metrics.shear = (a*b + c*d) / std::max(1e-12, metrics.scale_x * metrics.scale_y);
    metrics.translation_x = m.at<double>(0,2);
    metrics.translation_y = m.at<double>(1,2);
}

double percentile(std::vector<double> v, double p) {
    if (v.empty()) return 0.0;
    std::sort(v.begin(), v.end());
    const double idx = std::clamp(p, 0.0, 1.0) * (v.size()-1);
    const size_t lo = static_cast<size_t>(std::floor(idx)), hi = static_cast<size_t>(std::ceil(idx));
    if (lo == hi) return v[lo];
    const double t = idx - lo;
    return v[lo]*(1.0-t) + v[hi]*t;
}

void reprojectionMetrics(const cv::Mat& m,
                         const std::vector<cv::Point2f>& pts_b,
                         const std::vector<cv::Point2f>& pts_a,
                         const cv::Mat& inlier_mask, Metrics& metrics) {
    std::vector<double> errors;
    for (size_t i=0; i<pts_b.size(); ++i) {
        if (!inlier_mask.empty() && !inlier_mask.at<uchar>(static_cast<int>(i))) continue;
        const double x=m.at<double>(0,0)*pts_b[i].x+m.at<double>(0,1)*pts_b[i].y+m.at<double>(0,2);
        const double y=m.at<double>(1,0)*pts_b[i].x+m.at<double>(1,1)*pts_b[i].y+m.at<double>(1,2);
        errors.push_back(std::hypot(x-pts_a[i].x,y-pts_a[i].y));
    }
    metrics.median_reprojection_error = percentile(errors,0.50);
    metrics.p90_reprojection_error = percentile(errors,0.90);
}

struct Canvas { cv::Size size; cv::Point offset; cv::Mat warp_transform; };

Canvas canvasFor(const cv::Size& a_size, const cv::Size& b_size, const cv::Mat& m) {
    std::vector<cv::Point2f> corners{{0,0},{static_cast<float>(b_size.width),0},
        {static_cast<float>(b_size.width),static_cast<float>(b_size.height)},
        {0,static_cast<float>(b_size.height)}};
    std::vector<cv::Point2f> warped;
    cv::transform(corners, warped, m);
    double minx=0,miny=0,maxx=a_size.width,maxy=a_size.height;
    for (const auto& p:warped) { minx=std::min(minx,(double)p.x); miny=std::min(miny,(double)p.y); maxx=std::max(maxx,(double)p.x); maxy=std::max(maxy,(double)p.y); }
    const int fx=(int)std::floor(minx), fy=(int)std::floor(miny), cx=(int)std::ceil(maxx), cy=(int)std::ceil(maxy);
    cv::Point offset(-fx,-fy);
    cv::Mat wm=m.clone(); wm.at<double>(0,2)+=offset.x; wm.at<double>(1,2)+=offset.y;
    return {{cx-fx,cy-fy},offset,wm};
}

cv::Mat placeA(const cv::Mat& a, const Canvas& canvas, cv::Mat& mask) {
    cv::Mat out(canvas.size,a.type(),cv::Scalar::all(0));
    mask=cv::Mat(canvas.size,CV_8U,cv::Scalar(0));
    cv::Rect roi(canvas.offset.x,canvas.offset.y,a.cols,a.rows);
    a.copyTo(out(roi)); mask(roi).setTo(255); return out;
}

cv::Mat warpB(const cv::Mat& b, const Canvas& canvas, cv::Mat& mask) {
    cv::Mat out;
    cv::warpAffine(b,out,canvas.warp_transform,canvas.size,cv::INTER_LANCZOS4,cv::BORDER_CONSTANT);
    cv::Mat src_mask(b.size(),CV_8U,cv::Scalar(255));
    cv::warpAffine(src_mask,mask,canvas.warp_transform,canvas.size,cv::INTER_NEAREST,cv::BORDER_CONSTANT);
    return out;
}

cv::Mat residualCost(const cv::Mat& a,const cv::Mat& b,const cv::Mat& overlap) {
    cv::Mat ga=toGray8(a),gb=toGray8(b),gax,gay,gbx,gby;
    cv::Sobel(ga,gax,CV_32F,1,0,3); cv::Sobel(ga,gay,CV_32F,0,1,3);
    cv::Sobel(gb,gbx,CV_32F,1,0,3); cv::Sobel(gb,gby,CV_32F,0,1,3);
    cv::Mat intensity,gradx,grady,cost;
    cv::absdiff(ga,gb,intensity); intensity.convertTo(intensity,CV_32F);
    cv::absdiff(gax,gbx,gradx); cv::absdiff(gay,gby,grady);
    cost=intensity+0.20f*(gradx+grady); cv::GaussianBlur(cost,cost,cv::Size(3,3),0.8);
    cost.setTo(1e6f,overlap==0); return cost;
}

std::vector<int> verticalSeam(const cv::Mat& cost,const cv::Mat& overlap,double& mean_cost) {
    std::vector<cv::Point> nz; cv::findNonZero(overlap,nz);
    if(nz.empty()) throw std::runtime_error("images do not overlap after alignment");
    cv::Rect box=cv::boundingRect(nz); const int h=box.height,w=box.width; const float INF=1e20f;
    cv::Mat dp(h,w,CV_32F,cv::Scalar(INF)),parent(h,w,CV_16S,cv::Scalar(0));
    for(int x=0;x<w;++x){int xx=box.x+x;if(overlap.at<uchar>(box.y,xx))dp.at<float>(0,x)=cost.at<float>(box.y,xx);}
    for(int y=1;y<h;++y){int yy=box.y+y;for(int x=0;x<w;++x){int xx=box.x+x;if(!overlap.at<uchar>(yy,xx))continue;float best=INF;int best_dx=0;for(int dx=-1;dx<=1;++dx){int px=x+dx;if(px<0||px>=w)continue;float v=dp.at<float>(y-1,px);if(v<best){best=v;best_dx=dx;}}if(best<INF/2){dp.at<float>(y,x)=best+cost.at<float>(yy,xx);parent.at<short>(y,x)=(short)best_dx;}}}
    int end_x=-1;float best=INF;for(int x=0;x<w;++x)if(dp.at<float>(h-1,x)<best){best=dp.at<float>(h-1,x);end_x=x;}if(end_x<0)end_x=w/2;
    std::vector<int> seam(cost.rows,box.x+end_x);int x=end_x;double sum=0;int count=0;
    for(int y=h-1;y>=0;--y){int yy=box.y+y,xx=box.x+x;seam[yy]=xx;if(overlap.at<uchar>(yy,xx)){sum+=cost.at<float>(yy,xx);++count;}if(y>0)x+=parent.at<short>(y,x);x=std::clamp(x,0,w-1);}
    for(int y=0;y<box.y;++y)seam[y]=seam[box.y];for(int y=box.y+box.height;y<cost.rows;++y)seam[y]=seam[box.y+box.height-1];
    mean_cost=count?sum/count:0.0;return seam;
}

bool bExtendsRight(const cv::Mat& ma,const cv::Mat& mb) {
    cv::Mat only_a,only_b,na,nb;cv::bitwise_not(ma,na);cv::bitwise_not(mb,nb);cv::bitwise_and(ma,nb,only_a);cv::bitwise_and(mb,na,only_b);
    auto cx=[](const cv::Mat&m){auto mo=cv::moments(m,true);return mo.m00>0?mo.m10/mo.m00:0.0;};return cx(only_b)>=cx(only_a);
}

cv::Mat compose(const cv::Mat& a,const cv::Mat& b,const cv::Mat& ma,const cv::Mat& mb,const std::vector<int>& seam,int feather) {
    const bool b_right=bExtendsRight(ma,mb);cv::Mat af,bf;a.convertTo(af,CV_MAKETYPE(CV_32F,a.channels()));b.convertTo(bf,CV_MAKETYPE(CV_32F,b.channels()));cv::Mat out=af.clone();const int ch=a.channels();
    for(int y=0;y<a.rows;++y){int sx=seam[y];const float*ap=af.ptr<float>(y);const float*bp=bf.ptr<float>(y);float*op=out.ptr<float>(y);const uchar*pa=ma.ptr<uchar>(y);const uchar*pb=mb.ptr<uchar>(y);for(int x=0;x<a.cols;++x){if(!pa[x]&&!pb[x])continue;double wb=0;if(!pa[x])wb=1;else if(!pb[x])wb=0;else{double sd=b_right?(x-sx):(sx-x);wb=feather<=0?(sd>=0?1.0:0.0):std::clamp(0.5+sd/(2.0*feather),0.0,1.0);}for(int c=0;c<ch;++c){int i=x*ch+c;op[i]=(float)(ap[i]*(1.0-wb)+bp[i]*wb);}}}
    cv::Mat typed;out.convertTo(typed,a.type());return typed;
}

cv::Mat drawSeam(const cv::Mat& base,const std::vector<int>& seam,const cv::Mat& overlap){cv::Mat vis,gray=toGray8(base);cv::cvtColor(gray,vis,cv::COLOR_GRAY2BGR);for(int y=0;y<vis.rows;++y){int x=std::clamp(seam[y],0,vis.cols-1);if(overlap.at<uchar>(y,x))vis.at<cv::Vec3b>(y,x)=cv::Vec3b(0,0,255);}return vis;}

double maskedMeanAbsDiff(const cv::Mat&a,const cv::Mat&b,const cv::Mat&mask){cv::Mat ga=toGray8(a),gb=toGray8(b),diff;cv::absdiff(ga,gb,diff);return cv::mean(diff,mask)[0];}

int scoreConfidence(Metrics&m,const StitchOptions&o){double s=100;if(m.inliers<o.min_inliers)s-=35;if(m.inlier_ratio<o.min_inlier_ratio)s-=25;if(m.median_reprojection_error>o.ransac_reproj_threshold)s-=20;if(m.p90_reprojection_error>o.ransac_reproj_threshold*2)s-=15;if(m.scale_x<o.min_scale||m.scale_x>o.max_scale||m.scale_y<o.min_scale||m.scale_y>o.max_scale)s-=30;if(std::abs(m.rotation_deg)>o.max_abs_rotation_deg)s-=25;if(std::abs(m.shear)>0.02)s-=20;if(m.overlap_fraction<0.03||m.overlap_fraction>0.85)s-=20;if(m.improvement<0.10)s-=25;return std::clamp((int)std::lround(s),0,100);}

void addRejections(Metrics&m,const StitchOptions&o){if(m.inliers<o.min_inliers)m.rejection_reasons.push_back("too few RANSAC inliers");if(m.inlier_ratio<o.min_inlier_ratio)m.rejection_reasons.push_back("low inlier ratio");if(m.scale_x<o.min_scale||m.scale_x>o.max_scale||m.scale_y<o.min_scale||m.scale_y>o.max_scale)m.rejection_reasons.push_back("scale outside prototype sanity range");if(std::abs(m.rotation_deg)>o.max_abs_rotation_deg)m.rejection_reasons.push_back("rotation outside prototype sanity range");if(std::abs(m.shear)>0.02)m.rejection_reasons.push_back("excessive shear");if(m.overlap_fraction<0.03)m.rejection_reasons.push_back("implausibly small overlap");if(m.improvement<0.10)m.rejection_reasons.push_back("alignment does not materially reduce overlap residual");}

} // namespace

Stitcher::Stitcher(StitchOptions options):options_(options){}

StitchResult Stitcher::stitch(const cv::Mat& input_a,const cv::Mat& input_b,const std::optional<fs::path>& debug_dir) const {
    if(input_a.empty()||input_b.empty())throw std::runtime_error("input image is empty");if(debug_dir)fs::create_directories(*debug_dir);
    const cv::Mat a=input_a;cv::Mat b=normalizeChannelsAndDepth(input_b,a);if(options_.rotate_b_180)cv::rotate(b,b,cv::ROTATE_180);
    auto wa=makeWorkImage(a,options_.work_megapixels),wb=makeWorkImage(b,options_.work_megapixels);auto matches=matchSift(wa.gray,wb.gray,options_.ratio_test);
    StitchResult r;r.metrics.keypoints_a=(int)matches.keypoints_a.size();r.metrics.keypoints_b=(int)matches.keypoints_b.size();r.metrics.candidate_matches=matches.candidate_matches;r.metrics.mutual_matches=(int)matches.mutual.size();if(matches.mutual.size()<4)throw std::runtime_error("not enough mutual feature matches");
    auto pts_a=pointsFromMatches(matches.keypoints_a,matches.mutual,true),pts_b=pointsFromMatches(matches.keypoints_b,matches.mutual,false);Model requested=options_.model,estimate_model=requested==Model::Affine?Model::Affine:Model::Similarity;cv::Mat inliers;cv::Mat wt=estimateTransform(pts_b,pts_a,estimate_model,options_.ransac_reproj_threshold,inliers);if(wt.empty())throw std::runtime_error("RANSAC transform estimation failed");
    Model selected=requested;if(requested==Model::Auto){Metrics tmp;cv::Mat s;wt.convertTo(s,CV_64F);decompose(s,tmp);if(std::abs(tmp.rotation_deg)<0.08&&std::abs(tmp.scale_x-1.0)<0.0015)selected=Model::Translation;else if(std::abs(tmp.scale_x-1.0)<0.0015)selected=Model::Rigid;else selected=Model::Similarity;if(selected!=Model::Similarity)wt=estimateTransform(pts_b,pts_a,selected,options_.ransac_reproj_threshold,inliers);}else if(requested!=estimate_model)wt=estimateTransform(pts_b,pts_a,requested,options_.ransac_reproj_threshold,inliers);
    r.metrics.selected_model=modelName(selected==Model::Auto?Model::Similarity:selected);r.metrics.inliers=cv::countNonZero(inliers);r.metrics.inlier_ratio=(double)r.metrics.inliers/matches.mutual.size();cv::Mat full=scaleTransformToFull(wt,wa.scale,wb.scale);r.transform_b_to_a=full.clone();decompose(full,r.metrics);cv::Mat wt64;wt.convertTo(wt64,CV_64F);reprojectionMetrics(wt64,pts_b,pts_a,inliers,r.metrics);
    Canvas canvas=canvasFor(a.size(),b.size(),full);cv::Mat ma,mb,ca=placeA(a,canvas,ma),cb=warpB(b,canvas,mb),overlap;cv::bitwise_and(ma,mb,overlap);double op=cv::countNonZero(overlap);r.metrics.overlap_fraction=op/std::max(1.0,(double)std::min(a.total(),b.total()));if(op<=0)throw std::runtime_error("estimated transform produces no overlap");cv::Mat cost=residualCost(ca,cb,overlap);auto seam=verticalSeam(cost,overlap,r.metrics.seam_mean_cost);
    int bw=std::min(a.cols,b.cols),bh=std::min(a.rows,b.rows);cv::Mat base_mask(bh,bw,CV_8U,cv::Scalar(255));r.metrics.residual_before=maskedMeanAbsDiff(a(cv::Rect(0,0,bw,bh)),b(cv::Rect(0,0,bw,bh)),base_mask);r.metrics.residual_after=maskedMeanAbsDiff(ca,cb,overlap);r.metrics.improvement=r.metrics.residual_before>1e-9?(r.metrics.residual_before-r.metrics.residual_after)/r.metrics.residual_before:0.0;r.metrics.confidence=scoreConfidence(r.metrics,options_);addRejections(r.metrics,options_);r.accepted=r.metrics.rejection_reasons.empty()&&r.metrics.confidence>=60;r.image=compose(ca,cb,ma,mb,seam,options_.feather_width);
    if(debug_dir){cv::Mat vis;std::vector<char> mask(matches.mutual.size(),0);for(int i=0;i<inliers.rows;++i)mask[i]=inliers.at<uchar>(i)?1:0;cv::drawMatches(wa.gray,matches.keypoints_a,wb.gray,matches.keypoints_b,matches.mutual,vis,cv::Scalar::all(-1),cv::Scalar::all(-1),mask,cv::DrawMatchesFlags::NOT_DRAW_SINGLE_POINTS);cv::imwrite((*debug_dir/"matches-inliers.jpg").string(),vis);cv::imwrite((*debug_dir/"overlap.png").string(),overlap);cv::imwrite((*debug_dir/"seam.jpg").string(),drawSeam(ca,seam,overlap));std::ofstream f(*debug_dir/"metrics.json");f<<metricsJson(r.metrics)<<'\n';}
    return r;
}

Model Stitcher::parseModel(const std::string&v){if(v=="auto")return Model::Auto;if(v=="translation")return Model::Translation;if(v=="rigid")return Model::Rigid;if(v=="similarity")return Model::Similarity;if(v=="affine")return Model::Affine;throw std::invalid_argument("unknown model: "+v);}
std::string Stitcher::modelName(Model m){switch(m){case Model::Auto:return"auto";case Model::Translation:return"translation";case Model::Rigid:return"rigid";case Model::Similarity:return"similarity";case Model::Affine:return"affine";}return"unknown";}

std::string Stitcher::metricsJson(const Metrics&m){auto esc=[](const std::string&s){std::string o;for(char c:s){if(c=='\"'||c=='\\')o+='\\';o+=c;}return o;};std::ostringstream os;os<<std::fixed<<std::setprecision(6);os<<"{\n"<<"  \"selected_model\": \""<<esc(m.selected_model)<<"\",\n"<<"  \"keypoints_a\": "<<m.keypoints_a<<",\n"<<"  \"keypoints_b\": "<<m.keypoints_b<<",\n"<<"  \"candidate_matches\": "<<m.candidate_matches<<",\n"<<"  \"mutual_matches\": "<<m.mutual_matches<<",\n"<<"  \"inliers\": "<<m.inliers<<",\n"<<"  \"inlier_ratio\": "<<m.inlier_ratio<<",\n"<<"  \"median_reprojection_error\": "<<m.median_reprojection_error<<",\n"<<"  \"p90_reprojection_error\": "<<m.p90_reprojection_error<<",\n"<<"  \"rotation_deg\": "<<m.rotation_deg<<",\n"<<"  \"scale_x\": "<<m.scale_x<<",\n"<<"  \"scale_y\": "<<m.scale_y<<",\n"<<"  \"shear\": "<<m.shear<<",\n"<<"  \"translation_x\": "<<m.translation_x<<",\n"<<"  \"translation_y\": "<<m.translation_y<<",\n"<<"  \"overlap_fraction\": "<<m.overlap_fraction<<",\n"<<"  \"residual_before\": "<<m.residual_before<<",\n"<<"  \"residual_after\": "<<m.residual_after<<",\n"<<"  \"improvement\": "<<m.improvement<<",\n"<<"  \"seam_mean_cost\": "<<m.seam_mean_cost<<",\n"<<"  \"confidence\": "<<m.confidence<<",\n"<<"  \"rejection_reasons\": [";for(size_t i=0;i<m.rejection_reasons.size();++i){if(i)os<<", ";os<<"\""<<esc(m.rejection_reasons[i])<<"\"";}os<<"]\n}";return os.str();}

} // namespace magstitch
