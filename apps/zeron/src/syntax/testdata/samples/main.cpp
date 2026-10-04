#include <vector>
#include "local.hpp"
namespace app {
template <typename T>
class Box final : public Base<T> {
public:
    explicit Box(T value) noexcept : value_(std::move(value)) {}
    virtual ~Box() = default;
    auto get() const -> const T& { return value_; }
    static constexpr int kMax = 10;
private:
    T value_;
};
}  // namespace app
int main() {
    auto lambda = [&](int x) mutable { return x * 2; };
    std::vector<int> v{1, 2, 3};
    for (auto& x : v) { x = lambda(x); }
    app::Box<int> b(42);
    return nullptr == &b ? 1 : 0;
}
