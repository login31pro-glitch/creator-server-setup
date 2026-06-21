# Supabase Configuration for Creator Servers

This directory contains the essential SQL scripts and configuration files required to provision a **Creator Server**.

## What is a Creator Server?
A Creator Server allows community members, specifically those with the **content creator** role, to host their own independent, fully-functional instance of the backend database. By executing these scripts against a fresh Supabase project, you will automatically construct the exact database schema, Row Level Security (RLS) policies, secure triggers, and remote procedure calls (RPCs) utilized by the official server.

## Contents
Here is a breakdown of the scripts included. They handle database migrations in a modular approach:

- **`setup.sql`**: The primary initialization script. It builds the core tables, sets up secure triggers (including role protections), and defines all necessary data structures for moderation, leaderboards, and user profiles.
- **`setup_auth_rpc.sql`**: Sets up remote procedure calls (RPCs) regarding authentication and user initialization.
- **`ranked_system.sql`**: Schema and functions for the ranked gameplay tracking and leaderboards.
- **`challenges_tournaments.sql` / `challenges.sql`**: Creates tables and policies for user challenges and tournament events.
- **`backend_rpc.sql`**: General backend utility procedures used by the frontend.
- **`add_delete_policies.sql`**: Configures specific row-level security (RLS) deletion policies for cascade management.
- **`Setup_UpdateProfilesTable_rpc.sql`**: Logic covering secure profile updates and syncing.
- **`Setup_UpdatePromotion_rpc.sql`**: Procedures handling user promotions and role grants securely.
- **`SetupRealtime.sql`**: Configures Supabase Realtime tracking for live features (like active leaderboards, chat, or challenge sync).
- **`SetupCreatorRoles.sql`**: Defines specific permissions and Creator roles required for external instances.

## Getting Started
To set up your own Creator Server backend:
1. Create a new project on [Supabase](https://supabase.com/).
2. Navigate to the **SQL Editor** in your Supabase dashboard.
3. You will need to run the scripts from your local repository. Start by copying and executing **`setup.sql`** to initialize your base database structure.
4. Execute the remainder of the `.sql` scripts (e.g., `ranked_system.sql`, `SetupRealtime.sql`, etc.) sequentially to install all core functionalities, RPCs, and Realtime configurations.
5. Once all scripts have run successfully, your backend will mirror the exact infrastructure required for the client application!
