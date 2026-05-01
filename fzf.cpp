// fzf.cpp - minimal multicore fuzzy find + TUI
// Build: g++ -O2 -std=c++17 -pthread fzf.cpp -o fzf
// g++ -O2 -std=c++17 -pthread -c fzf.cpp -o obj/fzf.o && g++ -O2 -std=c++17 -pthread obj/fzf.o -o bin/fzf
// Usage: fzf <query> [path]

#include <algorithm>
#include <atomic>
#include <cctype>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
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

#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

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

// ---------- match result ----------
struct MatchResult {
    std::string path;
    int score;
};

// ---------- thread-safe results container ----------
class MatchResults {
    std::vector<MatchResult> results;
    std::mutex mtx;
public:
    void add(std::string path, int score) {
        std::lock_guard<std::mutex> lk(mtx);
        results.push_back({std::move(path), score});
    }

    std::vector<MatchResult> sorted() {
        std::lock_guard<std::mutex> lk(mtx);
        auto copy = results;
        std::sort(copy.begin(), copy.end(),
                  [](const MatchResult& a, const MatchResult& b) {
                      return a.score > b.score;
                  });
        return copy;
    }

    size_t size() {
        std::lock_guard<std::mutex> lk(mtx);
        return results.size();
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
MatchResults match_results;
std::string query;
int tty_fd = STDIN_FILENO;
bool filter_mode = false;

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

        match_results.add(path, s);
    }
}

// ---------- TUI ----------
struct Terminal {
    struct termios orig;
    int rows, cols;

    void enter_raw() {
        tcgetattr(tty_fd, &orig);
        struct termios raw = orig;
        raw.c_lflag &= ~(ICANON | ECHO);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 1;
        tcsetattr(tty_fd, TCSAFLUSH, &raw);
    }

    void restore() {
        tcsetattr(tty_fd, TCSAFLUSH, &orig);
    }

    void update_size() {
        struct winsize ws;
        ioctl(tty_fd, TIOCGWINSZ, &ws);
        rows = ws.ws_row;
        cols = ws.ws_col;
    }
};

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-result"
void write_stderr(const std::string& s) {
    write(STDERR_FILENO, s.data(), s.size());
}
#pragma GCC diagnostic pop

enum class Key { UP, DOWN, ENTER, QUIT, NONE };

Key read_key() {
    char c;
    if (read(tty_fd, &c, 1) != 1) return Key::NONE;

    if (c == '\n' || c == '\r') return Key::ENTER;
    if (c == 'q') return Key::QUIT;
    if (c == 'k') return Key::UP;
    if (c == 'j') return Key::DOWN;

    if (c == '\033') {
        char seq[2];
        if (read(tty_fd, &seq[0], 1) != 1) return Key::QUIT;
        if (read(tty_fd, &seq[1], 1) != 1) return Key::QUIT;
        if (seq[0] == '[') {
            if (seq[1] == 'A') return Key::UP;
            if (seq[1] == 'B') return Key::DOWN;
        }
        return Key::NONE;
    }
    return Key::NONE;
}

void run_tui() {
    auto results = match_results.sorted();
    if (results.empty()) {
        std::cerr << "No matches found.\n";
        return;
    }

    Terminal term;
    term.update_size();
    term.enter_raw();

    // alternate screen buffer, hide cursor
    std::string buf;
    buf += "\033[?1049h\033[?25l";
    write_stderr(buf);

    int selected = 0;
    int offset = 0;
    int visible = term.rows - 2;

    auto draw = [&]() {
        buf.clear();
        buf += "\033[H"; // cursor home

        // header
        buf += "\033[1;37;44m fzf > ";
        buf += query;
        int pad = term.cols - 7 - (int)query.size();
        if (pad > 0) buf.append(pad, ' ');
        buf += "\033[0m\n";

        // results
        for (int i = 0; i < visible; ++i) {
            int idx = offset + i;
            if (idx < (int)results.size()) {
                if (idx == selected) {
                    buf += "\033[1;33m> ";
                    buf += results[idx].path;
                    buf += "\033[0m";
                } else {
                    buf += "  ";
                    buf += results[idx].path;
                }
            }
            buf += "\033[K\n"; // clear to end of line
        }

        // footer
        buf += "\033[";
        buf += std::to_string(term.rows);
        buf += ";1H";
        buf += "\033[1;37;44m ";
        buf += std::to_string(results.size());
        buf += " matches | \xe2\x86\x91\xe2\x86\x93/jk navigate | Enter select | q quit";
        int fpad = term.cols - 52;
        if (fpad > 0) buf.append(fpad, ' ');
        buf += "\033[0m";

        write_stderr(buf);
    };

    draw();

    bool running = true;
    while (running) {
        Key k = read_key();
        switch (k) {
        case Key::UP:
            if (selected > 0) --selected;
            if (selected < offset) offset = selected;
            break;
        case Key::DOWN:
            if (selected < (int)results.size() - 1) ++selected;
            if (selected >= offset + visible) offset = selected - visible + 1;
            break;
        case Key::ENTER:
            // restore terminal, print selection to stdout
            buf.clear();
            buf += "\033[?25h\033[?1049l";
            write_stderr(buf);
            term.restore();
            std::cout << results[selected].path << '\n';
            return;
        case Key::QUIT:
            running = false;
            break;
        case Key::NONE:
            break;
        }
        draw();
    }

    // restore terminal without printing selection
    buf.clear();
    buf += "\033[?25h\033[?1049l";
    write_stderr(buf);
    term.restore();
}

// ---------- main ----------
int main(int argc, char** argv) {

    // parse flags first so we know if we need the TUI
    std::vector<std::string> positional;
    std::string root = ".";
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--filter") == 0) filter_mode = true;
        else positional.push_back(argv[i]);
    }

    // check if we are being piped to first, if so we dont really even need
    //      other args
    // when stdin is a pipe, keyboard input comes from /dev/tty instead
    bool piped = !isatty(STDIN_FILENO);
    if (piped && !filter_mode) {
        tty_fd = open("/dev/tty", O_RDONLY);
        if (tty_fd < 0) {
            std::cerr << "fzf: cannot open /dev/tty\n";
            return 1;
        }
    }

    if (positional.size() > 2)
    {
        std::cerr << "too many args, usage: fzf [--filter] <query> [path]\n";
    }
    else if (positional.size() == 2)
    {
        query = positional[0];
        root  = positional[1];
    }
    else if (positional.size() == 1)
    {
        query = positional[0];
    }
    else if (positional.size() == 0 && piped)
    {
        //dont really need to do anything here, just using fzf as a list picker
        NULL;
    }
    //eventuall need something here if size is 0 and not piped just find all files
    else
    {
        //something is wrong with the arguments or usage
        std::cerr << "usage: fzf [--filter] <query> [path]\n";
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

    if (piped)
    {
        // read paths from stdin pipe
        std::string line;
        while (std::getline(std::cin, line)) {
            if (!line.empty()) q.push(std::move(line));
        }
    } 
    else //if not piped
    {
        // check for FZF_DEFAULT_COMMAND env var
        const char* cmd = std::getenv("FZF_DEFAULT_COMMAND");
        if (cmd && cmd[0]) {
            FILE* fp = popen(cmd, "r");
            if (fp) {
                char buf[4096];
                while (std::fgets(buf, sizeof(buf), fp)) {
                    std::string line(buf);
                    if (!line.empty() && line.back() == '\n') line.pop_back();
                    if (!line.empty()) q.push(std::move(line));
                }
                pclose(fp);
            }
        }
        else //if env default command not set use built in walker
        {
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
        }
    }

    q.close();
    for (auto& t : workers) t.join();

    if (filter_mode) {
        auto results = match_results.sorted();
        for (auto& r : results)
            std::cout << r.path << '\n';
    } else {
        run_tui();
    }

    if (piped && tty_fd != STDIN_FILENO) close(tty_fd);
    return 0;
}
