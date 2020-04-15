#ifndef SEED_TESTER_RANDOM_H
#define SEED_TESTER_RANDOM_H
#define ulong uint64_t
#include <cstdint>
#include <stdexcept>

namespace random_math
{

    class LCG {
    public:
        int64_t multiplier;
        int64_t addend;
        int64_t modulo;
        bool maskable;

        LCG(int64_t multiplier, int64_t addend, int64_t modulo, bool maskable = true);

        int64_t next(int64_t seed);

        LCG combine(int64_t steps);

    };

    class JavaRand {
    private:
        uint64_t seed;
    public:
        static LCG lcg;
        static void init();

        explicit JavaRand(long seed, bool scramble = true);
        uint64_t getSeed();
        void setSeed(int64_t seed, bool scramble = true);
        uint32_t next(int32_t bits);
        uint32_t nextInt(int32_t bound);
        /* bound must be a positive power of 2 */
        uint32_t nextIntPow2Unchecked(int32_t bound);
    };

}






#endif //SEED_TESTER_RANDOM_H
