use ExtUtils::MakeMaker;

WriteMakefile(
              NAME	=> 'Finance::Bank::IE',
              VERSION => '0.23',
              AUTHOR  => 'Ronan Waide <waider@waider.ie>',
              PREREQ_PM   => {
                              'WWW::Mechanize'	=> '0',
                              'Date::Parse' => '0',
                              'HTML::TokeParser' => '0',
                              'HTML::Entities' => '0',
                             },
             );
