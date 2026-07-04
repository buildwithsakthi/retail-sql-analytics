"""Generate the Cartwheel & Co. SQLite database (retail.db).

Standard library only -- no dependencies to install. The random seed is
fixed, so everyone who runs this gets byte-identical data and the numbers
quoted in queries.sql / README.md reproduce exactly.

Usage:  python generate_data.py
"""

import random
import sqlite3
from datetime import date, timedelta
from pathlib import Path

random.seed(42)

DB_PATH = Path(__file__).parent / "retail.db"
SCHEMA_PATH = Path(__file__).parent / "schema.sql"

STORE_OPENED = date(2023, 1, 1)
LAST_DAY = date(2025, 6, 30)
SIGNUP_CUTOFF = date(2025, 5, 31)   # leave a few weeks of order history after the last signup

# ---------------------------------------------------------------- catalog

# (category, price range, margin range) -- electronics skew expensive,
# which is what makes the revenue-vs-volume queries interesting
CATEGORIES = [
    ("Electronics",      (24.99, 449.99), (0.55, 0.75)),
    ("Home & Kitchen",   (12.99, 189.99), (0.45, 0.65)),
    ("Sports & Outdoors", (9.99, 159.99), (0.45, 0.65)),
    ("Beauty",            (6.99,  59.99), (0.30, 0.50)),
    ("Toys & Games",      (8.99,  79.99), (0.40, 0.60)),
    ("Office Supplies",   (3.99,  49.99), (0.40, 0.60)),
]

PRODUCT_WORDS = {
    "Electronics": (["Wireless", "Smart", "Compact", "Pro", "Portable", "HD"],
                    ["Earbuds", "Speaker", "Webcam", "Keyboard", "Monitor", "Charger",
                     "Headphones", "Mouse", "Power Bank", "Soundbar"]),
    "Home & Kitchen": (["Ceramic", "Stainless", "Nonstick", "Bamboo", "Cast Iron", "Glass"],
                       ["Skillet", "Kettle", "Knife Set", "Mixing Bowl", "Storage Jar",
                        "Cutting Board", "Dutch Oven", "Toaster", "French Press", "Baking Sheet"]),
    "Sports & Outdoors": (["Trail", "Aero", "Flex", "Summit", "Hydro", "Core"],
                          ["Yoga Mat", "Water Bottle", "Resistance Bands", "Backpack",
                           "Jump Rope", "Foam Roller", "Camping Lantern", "Bike Light",
                           "Running Belt", "Dumbbell Set"]),
    "Beauty": (["Hydrating", "Vitamin C", "Charcoal", "Botanical", "Overnight", "Daily"],
               ["Face Serum", "Moisturizer", "Cleanser", "Lip Balm", "Face Mask",
                "Eye Cream", "Toner", "Sunscreen", "Hand Cream", "Shampoo Bar"]),
    "Toys & Games": (["Wooden", "Magnetic", "Classic", "Junior", "Deluxe", "Mini"],
                     ["Building Blocks", "Puzzle", "Card Game", "Art Kit", "Race Track",
                      "Plush Bear", "Science Kit", "Board Game", "Robot Kit", "Dollhouse"]),
    "Office Supplies": (["Ergonomic", "Recycled", "Premium", "Dual", "Adjustable", "Leather"],
                        ["Notebook", "Desk Organizer", "Gel Pens", "Planner", "Mouse Pad",
                         "Stapler", "Desk Lamp", "File Folders", "Whiteboard", "Sticky Notes"]),
}

FIRST_NAMES = ["James", "Maria", "Wei", "Aisha", "Carlos", "Emily", "Raj", "Sofia",
               "Daniel", "Keiko", "Ahmed", "Hannah", "Luis", "Priya", "Michael",
               "Fatima", "Jordan", "Elena", "Tyler", "Nina", "Andre", "Grace",
               "Hassan", "Olivia", "Diego", "Amara", "Ethan", "Lucia", "Sam", "Zoe"]
LAST_NAMES = ["Smith", "Garcia", "Chen", "Johnson", "Patel", "Kim", "Brown", "Nguyen",
              "Davis", "Martinez", "Wilson", "Ali", "Anderson", "Lopez", "Taylor",
              "Singh", "Thomas", "Rivera", "Moore", "Khan", "Jackson", "Torres",
              "White", "Yamamoto", "Harris", "Okafor", "Clark", "Reyes", "Lewis", "Novak"]

CITIES = [("New York", "NY"), ("Los Angeles", "CA"), ("Chicago", "IL"),
          ("Houston", "TX"), ("Phoenix", "AZ"), ("Philadelphia", "PA"),
          ("San Antonio", "TX"), ("San Diego", "CA"), ("Dallas", "TX"),
          ("Austin", "TX"), ("Seattle", "WA"), ("Denver", "CO"),
          ("Boston", "MA"), ("Atlanta", "GA"), ("Miami", "FL"),
          ("Portland", "OR"), ("Charlotte", "NC"), ("Columbus", "OH"),
          ("Nashville", "TN"), ("Minneapolis", "MN")]

# acquisition mix, and how likely each channel's customers are to come back.
# referral customers repeat noticeably more -- a deliberate (and realistic)
# pattern that several queries surface.
CHANNELS = ["organic", "paid_search", "social", "referral"]
CHANNEL_WEIGHTS = [0.45, 0.25, 0.15, 0.15]
REPEAT_PROB = {"organic": 0.62, "paid_search": 0.54, "social": 0.52, "referral": 0.78}


def make_products():
    products = []  # (product_id, category_id, name, list_price, unit_cost)
    pid = 1
    used_names = set()
    for cat_id, (cat, (lo, hi), (mlo, mhi)) in enumerate(CATEGORIES, start=1):
        adjectives, nouns = PRODUCT_WORDS[cat]
        for _ in range(25):
            while True:
                name = f"{random.choice(adjectives)} {random.choice(nouns)}"
                if name not in used_names:
                    used_names.add(name)
                    break
            price = round(random.uniform(lo, hi), 2)
            margin = random.uniform(mlo, mhi)
            cost = round(price * (1 - margin), 2)
            products.append((pid, cat_id, name, price, cost))
            pid += 1
    return products


def make_customers(n=1500):
    customers = []  # (id, first, last, email, city, state, channel, signup_date)
    span = (SIGNUP_CUTOFF - STORE_OPENED).days
    for cid in range(1, n + 1):
        first = random.choice(FIRST_NAMES)
        last = random.choice(LAST_NAMES)
        email = f"{first.lower()}.{last.lower()}{cid}@example.com"
        city, state = random.choice(CITIES)
        channel = random.choices(CHANNELS, CHANNEL_WEIGHTS)[0]
        # triangular weighting -> more signups in later months (the store is growing)
        offset = int(random.triangular(0, span, span * 0.75))
        signup = STORE_OPENED + timedelta(days=offset)
        customers.append((cid, first, last, email, city, state, channel,
                          signup.isoformat()))
    return customers


def make_orders(customers, products):
    """Order dates follow each customer's rhythm: first order shortly after
    signup, then gaps of a few weeks to a few months while they stay active.
    A holiday bump adds extra November/December orders."""
    orders = []       # (order_id, customer_id, order_date, status)
    items = []        # (order_item_id, order_id, product_id, qty, unit_price)

    # long-tail popularity: a handful of products get most of the sales
    weights = [random.lognormvariate(0, 1) for _ in products]

    oid = iid = 1
    for cust in customers:
        cid, channel, signup = cust[0], cust[6], date.fromisoformat(cust[7])

        if random.random() < 0.10:      # window shoppers: signed up, never bought
            continue

        order_dates = []
        d = signup + timedelta(days=random.randint(0, 21))
        p_repeat = REPEAT_PROB[channel]
        while d <= LAST_DAY and len(order_dates) < 15:
            order_dates.append(d)
            if random.random() > p_repeat:
                break
            d = d + timedelta(days=random.randint(14, 45) + int(random.expovariate(1 / 40)))

        # holiday bump: active customers often place an extra Nov/Dec order
        for yr in {dt.year for dt in order_dates}:
            if random.random() < 0.22:
                extra = date(yr, 11, 15) + timedelta(days=random.randint(0, 35))
                if signup <= extra <= LAST_DAY:
                    order_dates.append(extra)

        for d in sorted(order_dates):
            status = random.choices(["completed", "returned", "cancelled"],
                                    [0.92, 0.05, 0.03])[0]
            orders.append((oid, cid, d.isoformat(), status))

            n_lines = random.choices([1, 2, 3, 4], [0.50, 0.30, 0.14, 0.06])[0]
            for prod in random.choices(products, weights, k=n_lines):
                qty = random.choices([1, 2, 3], [0.75, 0.20, 0.05])[0]
                price = prod[3]
                if random.random() < 0.20:   # occasional promo pricing
                    price = round(price * random.uniform(0.75, 0.90), 2)
                items.append((iid, oid, prod[0], qty, price))
                iid += 1
            oid += 1

    return orders, items


def main():
    products = make_products()
    customers = make_customers()
    orders, items = make_orders(customers, products)

    if DB_PATH.exists():
        DB_PATH.unlink()
    con = sqlite3.connect(DB_PATH)
    con.executescript(SCHEMA_PATH.read_text())

    con.executemany("INSERT INTO categories VALUES (?, ?)",
                    [(i, c[0]) for i, c in enumerate(CATEGORIES, start=1)])
    con.executemany("INSERT INTO products VALUES (?, ?, ?, ?, ?)", products)
    con.executemany("INSERT INTO customers VALUES (?, ?, ?, ?, ?, ?, ?, ?)", customers)
    con.executemany("INSERT INTO orders VALUES (?, ?, ?, ?)", orders)
    con.executemany("INSERT INTO order_items VALUES (?, ?, ?, ?, ?)", items)
    con.commit()

    for table in ["categories", "products", "customers", "orders", "order_items"]:
        n = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"{table:<12} {n:>6} rows")
    lo, hi = con.execute("SELECT MIN(order_date), MAX(order_date) FROM orders").fetchone()
    print(f"\norders span {lo} .. {hi}")
    print(f"wrote {DB_PATH.name}")
    con.close()


if __name__ == "__main__":
    main()
