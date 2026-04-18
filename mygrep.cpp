// mygrep.cpp - minimal multicore fuzzy find + grep
// Build: g++ -O2 -std=c++17 -pthread mygrep.cpp -o mygrep
// g++ -O2 -std=c++17 -pthread -c mygrep.cpp -o obj/mygrep.o && g++ -O2 -std=c++17 -pthread obj/mygrep.o -o bin/mygrep
// Usage: mygrep [--files] <query> [path]
// --files : fd-mode (print matching paths only)
// default : rg-mode (print matching lines in files whose paths match query)

#include <atomic>
#include <cctype>
#include <condition_variable>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

namespace fs = std::filesystem;

// ---------- bounded concurrent queue ----------
template <typename T>
class BQueue {
    std::queue<T> q;
    std::mutex m;
    std::condition_variable cv_push, cv_pop;
    size_t cap;
    bool done = false;
public:
    explicit BQueue(size_t c) : cap(c) {}
    void push(T v) {
        std::unique_lock<std::mutex> lk(m);
        cv_push.wait(lk, [&]{ return q.size() < cap; });
        q.push(std::move(v));
        cv_pop.notify_one();
    }
    bool pop(T& out) {
        std::unique_lock<std::mutex> lk(m);
        cv_pop.wait(lk, [&]{ return !q.empty() || done; });
        if (q.empty()) return false;
        out = std::move(q.front()); q.pop();
        cv_push.notify_one();
        return true;
    }
    void close() {
        { std::lock_guard<std::mutex> lk(m); done = true; }
        cv_pop.notify_all();
    }
};

// ---------- fuzzy scorer (fzf-lite) ----------
// Returns -1 if query chars can't all be matched in order, else a score.
int fuzzy_score(const std::string& query, const std::string& text) {
    if (query.empty()) return 0;
    int score = 0, last_match = -2;
    size_t qi = 0;
    for (size_t i = 0; i < text.size() && qi < query.size(); ++i) {
        char tc = (char)std::tolower((unsigned char)text[i]);
        char qc = (char)std::tolower((unsigned char)query[qi]);
        if (tc == qc) {
            int bonus = 0;
            if (i == 0) bonus += 16;
            else {
                char prev = text[i-1];
                if (prev=='/'||prev=='_'||prev=='-'||prev=='.'||prev==' ')
                    bonus += 16;
                else if (std::islower((unsigned char)prev) &&
                         std::isupper((unsigned char)text[i]))
                    bonus += 8;
            }
            if ((int)i == last_match + 1) bonus += 4;
            score += bonus;
            last_match = (int)i;
            ++qi;
        } else {
            score -= 1;
        }
    }
    return qi == query.size() ? score : -1;
}

// ---------- skip list (tiny gitignore-lite) ----------
static const std::unordered_set<std::string> SKIP_DIRS = {
    ".git", "node_modules", "target", "build", ".venv", "__pycache__",
    ".cache", "dist", ".idea", ".vscode"
};

// ---------- binary detection ----------
bool looks_binary(const char* buf, size_t n) {
    size_t lim = n < 8192 ? n : 8192;
    for (size_t i = 0; i < lim; ++i) if (buf[i] == 0) return true;
    return false;
}

// ---------- case-insensitive substring search ----------
bool icontains(const std::string& hay, const std::string& needle) {
    if (needle.empty()) return true;
    if (needle.size() > hay.size()) return false;
    for (size_t i = 0; i + needle.size() <= hay.size(); ++i) {
        size_t j = 0;
        for (; j < needle.size(); ++j) {
            if (std::tolower((unsigned char)hay[i+j]) !=
                std::tolower((unsigned char)needle[j])) break;
        }
        if (j == needle.size()) return true;
    }
    return false;
}

// ---------- globals ----------
std::mutex cout_mtx;
bool files_mode = false;
std::string query;

// ---------- worker ----------
void worker(BQueue<std::string>& q) {
    std::string path;
    while (q.pop(path)) {
        // Score on filename first; fall back to full path if no match.
        size_t slash = path.rfind('/');
        std::string fname = (slash == std::string::npos) ? path : path.substr(slash + 1);
        int s = fuzzy_score(query, fname);
        if (s < 0) s = fuzzy_score(query, path);
        if (s < 0) continue;

        if (files_mode) {
            std::lock_guard<std::mutex> lk(cout_mtx);
            std::cout << path << '\n';
            continue;
        }

        // rg-mode: scan lines in the file for the query as substring
        std::ifstream in(path, std::ios::binary);
        if (!in) continue;
        std::string buf((std::istreambuf_iterator<char>(in)), {});
        if (buf.empty()) continue;
        if (looks_binary(buf.data(), buf.size())) continue;

        size_t lineno = 1, start = 0;
        for (size_t i = 0; i <= buf.size(); ++i) {
            if (i == buf.size() || buf[i] == '\n') {
                std::string line(buf.data() + start, i - start);
                if (icontains(line, query)) {
                    std::lock_guard<std::mutex> lk(cout_mtx);
                    std::cout << path << ':' << lineno << ':' << line << '\n';
                }
                start = i + 1;
                ++lineno;
            }
        }
    }
}

// ---------- main ----------
int main(int argc, char** argv) {
    std::vector<std::string> args(argv + 1, argv + argc);
    std::string root = ".";
    for (size_t i = 0; i < args.size(); ++i) {
        if (args[i] == "--files") files_mode = true;
        else if (query.empty()) query = args[i];
        else root = args[i];
    }
    if (query.empty()) {
        std::cerr << "usage: mygrep [--files] <query> [path]\n";
        return 1;
    }

    unsigned n = std::thread::hardware_concurrency();
    if (n == 0) n = 4;

    BQueue<std::string> q(1024);
    std::vector<std::thread> workers;
    for (unsigned i = 0; i < n; ++i) workers.emplace_back(worker, std::ref(q));

    std::error_code ec;
    fs::recursive_directory_iterator it(root,
        fs::directory_options::skip_permission_denied, ec), end;
    while (!ec && it != end) {
        const auto& p = it->path();
        if (it->is_directory(ec) && SKIP_DIRS.count(p.filename().string())) {
            it.disable_recursion_pending();
        } else if (it->is_regular_file(ec)) {
            q.push(p.string());
        }
        it.increment(ec);
    }
    q.close();
    for (auto& t : workers) t.join();
    return 0;
}
