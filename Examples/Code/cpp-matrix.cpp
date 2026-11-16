#include <array>
#include <iostream>

template <typename T, std::size_t N>
class Matrix {
public:
    constexpr T& operator()(std::size_t r, std::size_t c) { return data_[r * N + c]; }
    constexpr const T& operator()(std::size_t r, std::size_t c) const { return data_[r * N + c]; }

    Matrix operator*(const Matrix& other) const {
        Matrix out{};
        for (std::size_t i = 0; i < N; ++i)
            for (std::size_t j = 0; j < N; ++j)
                for (std::size_t k = 0; k < N; ++k)
                    out(i, j) += (*this)(i, k) * other(k, j);
        return out;
    }

private:
    std::array<T, N * N> data_{};
};

int main() {
    Matrix<double, 2> m;
    m(0, 0) = 1.5; m(1, 1) = 2.0;
    auto sq = m * m;
    std::cout << "m^2(1,1) = " << sq(1, 1) << '\n';  // 4
    return 0;
}
