// fzf.cpp - minimal multicore fuzzy find + grep
// Build: g++ -O2 -std=c++17 -pthread fzf.cpp -o fzf
// g++ -O2 -std=c++17 -pthread -c fzf.cpp -o obj/fzf.o && g++ -O2 -std=c++17 -pthread obj/fzf.o -o bin/fzf
// Usage: fzf [--files] <query> [path]
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
    //Constructor
    explicit BQueue(size_t c) : cap(c) {}

    void push(T v) {
        //lock the mutex
        std::unique_lock<std::mutex> lk(m);
        //sleep this thread until the size of the queue is below capacity
        cv_push.wait(lk, [&]{ return q.size() < cap; });
        //once we wake up and continue, put the input on the queue, I have no clue why we use std::move 
        q.push(std::move(v));
        //notify a thread that we can work on the queue now
        cv_pop.notify_one();
    }
    bool pop(T& out) {
        //lock the mutex
        std::unique_lock<std::mutex> lk(m);
        //sleep this thread until the queue has something or done is true
        cv_pop.wait(lk, [&]{ return !q.empty() || done; });
        //if the queue is empty and we know already know dont is true from above then return false
        if (q.empty()) return false;
        //again I dont know what std::move is doing, pop off the top of queue
        out = std::move(q.front()); q.pop();
        //notify a thread that we can work on the queue now
        cv_push.notify_one();
        //if we got this far we know done is true and we have popped something off queue, return true
        return true;
    }
    void close() {
        { std::lock_guard<std::mutex> lk(m); done = true; }
        //wake everyone up so they can all see dont = true
        cv_pop.notify_all();
    }
};

// ---------- fuzzy scorer (fzf-lite) ----------
// Returns -1 if query chars can't all be matched in order, else a score.
int fuzzy_score(const std::string& query, const std::string& text) {
    if (query.empty()) return 0;
    int score = 0, last_match = -2;
    size_t query_index = 0;
    //end the loop when we hit the end of one of the strings
    for (size_t i = 0; i < text.size() && query_index < query.size(); ++i) {
        //lower case everything
        char tc = (char)std::tolower((unsigned char)text[i]);
        char qc = (char)std::tolower((unsigned char)query[query_index]);
        if (tc == qc) {
            int bonus = 0;
            //first character? super bonus
            if (i == 0) bonus += 16;
            else {
                char prev = text[i-1];
                //not the first char of the string but the previous char was /_-.? super bonus
                if (prev=='/'||prev=='_'||prev=='-'||prev=='.'||prev==' ')
                    bonus += 16;
                //CamelCase boundary detection
                //not the first char but this is an upper case char after a lower case one? small bonus
                else if (std::islower((unsigned char)prev) &&
                         std::isupper((unsigned char)text[i]))
                    bonus += 8;
            }
            //if this char is right after the last thing that matched? extra small bonus
            if ((int)i == last_match + 1) bonus += 4;
            //we matched a char, keep a runnign tally of the bonus
            score += bonus;
            last_match = (int)i;
            ++query_index;
        } else {
            //if we didnt match then start substracting for a gap penalty
            score -= 1;
        }
    }
    //when weve matched the entire query return the score, otherwise return -1 meaning no match
    return query_index == query.size() ? score : -1;
}

// ---------- skip list (tiny gitignore-lite) ----------
static const std::unordered_set<std::string> SKIP_DIRS = {
    ".git", "node_modules", "target", "build", ".venv", "__pycache__",
    ".cache", "dist", ".idea", ".vscode"
};

// ---------- globals ----------
//this is a mutex to make sure workers dont all cout at same time
std::mutex cout_mtx;
bool files_mode = false;
std::string query;

// ---------- worker ----------
void worker(BQueue<std::string>& q) {
    std::string path;
    //keep popping paths off the queue, we will leave this loop when queue is empty or we get mutex blocked
    while (q.pop(path))
    {
        // Score on filename first; fall back to full path if no match.
        size_t slash = path.rfind('/');
        std::string fname = (slash == std::string::npos) ? path : path.substr(slash + 1);
        int s = fuzzy_score(query, fname);
        if (s < 0) s = fuzzy_score(query, path);
        if (s < 0) continue;

        //make sure we can print
        std::lock_guard<std::mutex> lk(cout_mtx);
        //we did it! print to cmd line
        std::cout << path << '\n';
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
        std::cerr << "usage: fzf [--files] <query> [path]\n";
        return 1;
    }

    //get how many threads I have
    unsigned n = std::thread::hardware_concurrency();
    //if something went wrong just set threads to 4
    if (n == 0) n = 4;

    //cap the queue to size 1024
    BQueue<std::string> q(1024);
    std::vector<std::thread> workers;
    //spawn n threads
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
